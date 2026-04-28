import { Controller } from "@hotwired/stimulus"

// Full-screen visit recording stage. Three things happen in parallel
// while the RN is talking:
//
//   - Web Speech API streams interim + final transcripts into the
//     visible scroll panel; the final transcript becomes Visit#narrative.
//   - MediaRecorder captures the same audio stream as a webm/mp4 Blob
//     that ships up as Visit#audio_note (ActiveStorage).
//   - AnalyserNode + canvas paints a live frequency-bar waveform so the
//     RN sees the mic is working.
//
// On Stop we PATCH /visits/:id with multipart (narrative + audio_note),
// then redirect to /visits/:id/edit so the RN can review/correct
// before tapping Finish.

export default class extends Controller {
  static targets = ["timer", "status", "canvas", "transcript",
                    "recordButton", "recordIcon", "pauseButton", "stopButton",
                    "consentPanel", "stage"]
  static values = {
    updateUrl:  String,
    editUrl:    String,
    discardUrl: String,
    csrf:       String,
    lang:       { type: String, default: "en-US" }
  }

  connect() {
    this._audioChunks   = []
    this._stream        = null
    this._recorder      = null
    this._speech        = null
    this._listening     = false
    this._userStopped   = false
    this._uploaded      = false
    this._finalText     = ""
    this._interimText   = ""
    this._timerInterval = null
    this._rafId         = null
    this._startedAtMs   = 0
    this._pausedAtMs    = 0
    this._pausedTotalMs = 0

    // Browser back / tab close / hard reload all fire pagehide. If
    // the RN never tapped Stop, send a discard beacon so the visit
    // doesn't sit in :recording state forever. sendBeacon is
    // fire-and-forget but reliable across navigation.
    this._boundPageHide = this._onPageHide.bind(this)
    window.addEventListener("pagehide", this._boundPageHide)
  }

  disconnect() {
    window.removeEventListener("pagehide", this._boundPageHide)
    this._teardown()
  }

  _onPageHide() {
    // Only fire the discard if the RN never finished uploading.
    // After a clean Stop + redirect to edit, _uploaded is true and we
    // skip — the visit has real content now.
    if (this._uploaded) return
    if (!this.discardUrlValue) return
    const fd = new FormData()
    fd.append("authenticity_token", this.csrfValue)
    try {
      navigator.sendBeacon(this.discardUrlValue, fd)
    } catch (_) {}
  }

  // ── Top-level toggles ─────────────────────────────────────────────

  // Consent gate — shown first; the RN reads it, asks the patient,
  // then taps 'I have consent' which hides the panel and reveals
  // the mic stage.
  acknowledgeConsent() {
    if (this.hasConsentPanelTarget) this.consentPanelTarget.classList.add("hidden")
    if (this.hasStageTarget) {
      this.stageTarget.classList.remove("hidden")
      this.stageTarget.classList.add("flex")
    }
  }

  toggle() {
    if (this._listening) {
      this.stop()
    } else {
      this._start()
    }
  }

  togglePause() {
    if (!this._recorder) return
    if (this._recorder.state === "recording") {
      this._recorder.pause()
      try { this._speech?.stop() } catch (_) {}
      this._pausedAtMs = Date.now()
      this._setStatus("Paused")
      this._stopTimer()
      this._stopWaveform()
    } else if (this._recorder.state === "paused") {
      this._recorder.resume()
      try { this._speech?.start() } catch (_) {}
      this._pausedTotalMs += Date.now() - this._pausedAtMs
      this._setStatus("Recording…")
      this._startTimer()
      this._startWaveform()
    }
  }

  cancel(event) {
    // The cancel link is a real <a>; let it navigate but stop streams first.
    this._teardown()
    // No preventDefault — let the link follow.
    return true
  }

  // ── Recording lifecycle ──────────────────────────────────────────

  async _start() {
    let stream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (err) {
      this._setStatus("Microphone permission denied")
      console.warn("[voice-visit] mic permission denied:", err)
      return
    }
    this._stream      = stream
    this._userStopped = false
    this._audioChunks = []
    this._finalText   = ""
    this._interimText = ""
    this._startedAtMs = Date.now()
    this._pausedTotalMs = 0

    this._initSpeech()
    this._initRecorder(stream)
    this._initAnalyser(stream)

    try { this._speech?.start() } catch (_) {}
    this._recorder.start(1000)
    this._listening = true
    this._setStatus("Recording…")
    this._paintRecording()
    this._showStopAndPause()
    this._startTimer()
    this._startWaveform()

    // Clear the placeholder copy in the transcript panel.
    if (this.hasTranscriptTarget) this.transcriptTarget.innerHTML = ""
  }

  stop() {
    if (!this._listening) return
    this._userStopped = true
    this._listening = false
    try { this._speech?.stop() } catch (_) {}
    if (this._recorder && this._recorder.state !== "inactive") {
      try { this._recorder.stop() } catch (_) {}
    }
    this._setStatus("Saving…")
    this._stopTimer()
    this._stopWaveform()
  }

  _initSpeech() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition
    if (!SR) {
      this._speech = null
      return
    }
    const r = new SR()
    r.lang           = this.langValue || "en-US"
    r.continuous     = true
    r.interimResults = true
    r.onresult = (e) => {
      let interim = ""
      let final   = this._finalText
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const transcript = e.results[i][0].transcript
        if (e.results[i].isFinal) {
          final += transcript
        } else {
          interim += transcript
        }
      }
      this._finalText   = final
      this._interimText = interim
      this._renderTranscript()
    }
    r.onerror = (e) => console.warn("[voice-visit] speech error:", e.error)
    r.onend = () => {
      // SpeechRecognition self-ends on long silence even in continuous
      // mode. If the user hasn't pressed Stop, restart so the session
      // feels uninterrupted.
      if (!this._userStopped) {
        try { r.start() } catch (_) {}
      }
    }
    this._speech = r
  }

  _initRecorder(stream) {
    const mime = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]
                   .find((c) => MediaRecorder.isTypeSupported(c)) || ""
    this._recorder = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream)
    this._recorder.ondataavailable = (e) => { if (e.data && e.data.size > 0) this._audioChunks.push(e.data) }
    this._recorder.onstop = () => this._finalizeAndUpload()
  }

  _finalizeAndUpload() {
    const type = this._recorder.mimeType || "audio/webm"
    const ext  = type.includes("ogg") ? "ogg" : (type.includes("mp4") ? "m4a" : "webm")
    const blob = new Blob(this._audioChunks, { type })
    const file = new File([blob], `visit-audio-${Date.now()}.${ext}`, { type })
    const narrative = (this._finalText + " " + this._interimText).trim()

    const fd = new FormData()
    fd.append("visit[narrative]",  narrative)
    fd.append("visit[audio_note]", file, file.name)
    fd.append("_method",           "patch")

    fetch(this.updateUrlValue, {
      method:  "POST",
      headers: {
        "Accept":       "text/html",
        "X-CSRF-Token": this.csrfValue
      },
      body: fd
    }).then(() => {
      // Mark the visit as uploaded so the pagehide beacon doesn't
      // discard it on the redirect away from this screen.
      this._uploaded = true
      // Hand off to the edit page where the RN reviews + finishes.
      // Append a hint so the edit page knows to auto-extract vitals.
      window.location.href = `${this.editUrlValue}?just_recorded=1`
    }).catch((err) => {
      console.error("[voice-visit] upload failed:", err)
      this._setStatus("Upload failed; tap to retry")
      this._listening = false
      this._paintIdle()
    })

    this._teardownStream()
  }

  // ── Live waveform via AnalyserNode + canvas ──────────────────────

  _initAnalyser(stream) {
    const Ctx = window.AudioContext || window.webkitAudioContext
    if (!Ctx || !this.hasCanvasTarget) return
    this._audioCtx = new Ctx()
    const src = this._audioCtx.createMediaStreamSource(stream)
    this._analyser = this._audioCtx.createAnalyser()
    this._analyser.fftSize = 128
    src.connect(this._analyser)
    this._freqData = new Uint8Array(this._analyser.frequencyBinCount)

    // Size the canvas bitmap to its CSS box for sharp rendering on
    // high-DPR screens.
    const canvas = this.canvasTarget
    const dpr = window.devicePixelRatio || 1
    canvas.width  = canvas.clientWidth  * dpr
    canvas.height = canvas.clientHeight * dpr
    this._dpr = dpr
  }

  _startWaveform() {
    if (!this._analyser || !this.hasCanvasTarget) return
    const canvas = this.canvasTarget
    const ctx = canvas.getContext("2d")
    const draw = () => {
      this._analyser.getByteFrequencyData(this._freqData)
      const w = canvas.width
      const h = canvas.height
      ctx.clearRect(0, 0, w, h)

      // Vertical center line, bars grow up and down from middle.
      const bars = this._freqData.length
      const barGap   = 2 * this._dpr
      const barWidth = Math.max(2, (w - barGap * (bars - 1)) / bars)
      const mid = h / 2

      for (let i = 0; i < bars; i++) {
        const v = this._freqData[i] / 255   // 0..1
        const barH = Math.max(2 * this._dpr, v * h * 0.9)
        const x = i * (barWidth + barGap)
        // Color gradient: terracotta at peak, dim at low energy.
        const alpha = 0.35 + 0.65 * v
        ctx.fillStyle = `rgba(217, 119, 87, ${alpha})`
        ctx.fillRect(x, mid - barH / 2, barWidth, barH)
      }

      this._rafId = requestAnimationFrame(draw)
    }
    draw()
  }

  _stopWaveform() {
    if (this._rafId) cancelAnimationFrame(this._rafId)
    this._rafId = null
  }

  // ── Timer ─────────────────────────────────────────────────────────

  _startTimer() {
    if (this._timerInterval) clearInterval(this._timerInterval)
    this._timerInterval = setInterval(() => {
      if (!this.hasTimerTarget) return
      const elapsed = Date.now() - this._startedAtMs - this._pausedTotalMs
      const sec = Math.floor(elapsed / 1000)
      const m   = Math.floor(sec / 60)
      const s   = sec % 60
      this.timerTarget.textContent = `${m}:${String(s).padStart(2, "0")}`
    }, 250)
  }

  _stopTimer() {
    if (this._timerInterval) clearInterval(this._timerInterval)
    this._timerInterval = null
  }

  // ── UI helpers ────────────────────────────────────────────────────

  _paintRecording() {
    if (this.hasRecordButtonTarget) {
      this.recordButtonTarget.classList.add("animate-pulse")
      this.recordButtonTarget.dataset.state = "recording"
    }
    if (this.hasRecordIconTarget) {
      this.recordIconTarget.classList.remove("ri-mic-fill")
      this.recordIconTarget.classList.add("ri-stop-fill")
    }
  }

  _paintIdle() {
    if (this.hasRecordButtonTarget) {
      this.recordButtonTarget.classList.remove("animate-pulse")
      this.recordButtonTarget.dataset.state = "idle"
    }
    if (this.hasRecordIconTarget) {
      this.recordIconTarget.classList.remove("ri-stop-fill")
      this.recordIconTarget.classList.add("ri-mic-fill")
    }
  }

  _showStopAndPause() {
    if (this.hasStopButtonTarget) this.stopButtonTarget.classList.remove("hidden")
    if (this.hasPauseButtonTarget) this.pauseButtonTarget.classList.remove("hidden")
  }

  _setStatus(text) {
    if (this.hasStatusTarget) this.statusTarget.textContent = text
  }

  _renderTranscript() {
    if (!this.hasTranscriptTarget) return
    const finalEl   = `<span>${this._escape(this._finalText)}</span>`
    const interimEl = this._interimText
      ? ` <span class="text-white/50">${this._escape(this._interimText)}</span>`
      : ""
    this.transcriptTarget.innerHTML = finalEl + interimEl
    this.transcriptTarget.scrollTop = this.transcriptTarget.scrollHeight
  }

  _escape(s) {
    return String(s || "").replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    })[c])
  }

  _teardown() {
    this._stopTimer()
    this._stopWaveform()
    try { this._speech?.stop() } catch (_) {}
    if (this._recorder && this._recorder.state !== "inactive") {
      try { this._recorder.stop() } catch (_) {}
    }
    this._teardownStream()
    if (this._audioCtx) try { this._audioCtx.close() } catch (_) {}
  }

  _teardownStream() {
    if (this._stream) {
      this._stream.getTracks().forEach((t) => { try { t.stop() } catch (_) {} })
      this._stream = null
    }
  }
}
