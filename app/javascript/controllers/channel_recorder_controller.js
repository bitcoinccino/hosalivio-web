import { Controller } from "@hotwired/stimulus"

// Voice for team chat, trimmed from the patient chat:
//   mic    → Web Speech dictation into the input (edit before Send).
//   record → capture audio + a parallel Web Speech transcript, then
//            auto-send as a voice note (multipart POST). The new message
//            appears via the channel's Turbo stream, so no reload needed.
//
// Everything feature-detects and degrades gracefully (no mic / no Web
// Speech → the button just no-ops with a heads-up).
export default class extends Controller {
  static targets = ["input", "micButton", "recordButton", "status"]
  static values  = { postUrl: String }

  connect() {
    this._recording = false
    this._dictating = false
    this._chunks = []
  }

  disconnect() {
    this._stopStream()
    this._stopSpeech()
  }

  get _csrf() {
    return document.querySelector('meta[name="csrf-token"]')?.content || ""
  }

  // ── Mic: dictation only ───────────────────────────────────────────
  toggleMic() {
    if (this._recording) return
    if (this._dictating) return this._endDictation()

    const rec = this._newSpeech()
    if (!rec) { alert("Voice typing isn't supported in this browser."); return }
    this._micBase = this.inputTarget.value ? this.inputTarget.value.trim() + " " : ""
    rec.onresult = (e) => { this.inputTarget.value = this._micBase + this._readTranscript(e) }
    rec.onend    = () => { if (this._dictating) this._endDictation() }
    this._speech = rec
    rec.start()
    this._dictating = true
    this._setOn(this.micButtonTarget, true)
  }

  _endDictation() {
    this._stopSpeech()
    this._dictating = false
    if (this.hasMicButtonTarget) this._setOn(this.micButtonTarget, false)
  }

  // ── Record: audio + transcript, auto-send ─────────────────────────
  async toggleRecord() {
    if (this._recording) return this._finish()

    let stream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (_) {
      alert("Microphone access is needed to record a voice note.")
      return
    }
    this._stream = stream
    this._chunks = []
    this._cancelled = false

    const mime = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]
      .find((c) => window.MediaRecorder && MediaRecorder.isTypeSupported(c)) || ""
    this._mr = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream)
    this._mr.ondataavailable = (e) => { if (e.data && e.data.size) this._chunks.push(e.data) }
    this._mr.onstop = () => this._ship()

    // Parallel transcript (best-effort).
    this._transcript = ""
    this._micBase = ""
    const rec = this._newSpeech()
    if (rec) {
      rec.onresult = (e) => { this._transcript = this._readTranscript(e) }
      this._speech = rec
      try { rec.start() } catch (_) {}
    }

    this._mr.start()
    this._recording = true
    this._setOn(this.recordButtonTarget, true)
    if (this.hasStatusTarget) this.statusTarget.classList.remove("hidden")
  }

  cancel() {
    this._cancelled = true
    this._finish()
  }

  _finish() {
    this._stopSpeech()
    if (this._mr && this._mr.state !== "inactive") this._mr.stop()  // → _ship via onstop
    this._recording = false
    if (this.hasRecordButtonTarget) this._setOn(this.recordButtonTarget, false)
    if (this.hasStatusTarget) this.statusTarget.classList.add("hidden")
  }

  async _ship() {
    this._stopStream()
    const chunks = this._chunks
    this._chunks = []
    if (this._cancelled) { this._cancelled = false; return }
    if (!chunks.length) return

    const type = (this._mr && this._mr.mimeType) || "audio/webm"
    const ext  = type.includes("ogg") ? "ogg" : type.includes("mp4") ? "m4a" : "webm"
    const blob = new Blob(chunks, { type })
    const text = (this._transcript || "").trim()
    const file = new File([blob], `voice-note.${ext}`, { type })

    const fd = new FormData()
    fd.append("body", text)
    fd.append("audio", file, file.name)

    let resp
    try {
      resp = await fetch(this.postUrlValue, {
        method:  "POST",
        headers: { "Accept": "text/html", "X-CSRF-Token": this._csrf },
        body:    fd
      })
    } catch (_) {
      alert("Couldn't send the voice note — check your connection.")
      return
    }
    if (!resp.ok) { alert("Couldn't send the voice note."); return }
    // Message appends live via the channel's Turbo stream.
    this.inputTarget.value = ""
  }

  // ── helpers ───────────────────────────────────────────────────────
  _newSpeech() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition
    if (!SR) return null
    const rec = new SR()
    rec.continuous = true
    rec.interimResults = true
    rec.lang = "en-US"
    rec.onerror = () => {}
    return rec
  }

  _readTranscript(e) {
    let out = ""
    for (let i = 0; i < e.results.length; i++) out += e.results[i][0].transcript
    return out.trim()
  }

  _stopSpeech() {
    try { this._speech && this._speech.stop() } catch (_) {}
    this._speech = null
  }

  _stopStream() {
    if (this._stream) {
      this._stream.getTracks().forEach((t) => { try { t.stop() } catch (_) {} })
      this._stream = null
    }
  }

  _setOn(el, on) { if (el) el.dataset.on = on ? "true" : "false" }
}
