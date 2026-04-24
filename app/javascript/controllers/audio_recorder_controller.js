import { Controller } from "@hotwired/stimulus"

// Clinical audio recorder for the visit form.
// Captures raw audio via MediaRecorder, attaches the resulting Blob to
// a hidden file input on the form so it ships up to the server with the
// rest of the visit params. Distinct from the Dictate button (which is
// browser/Whisper transcription into the narrative text field) — this is
// the audio of the bedside, not just words.
//
//   <div data-controller="audio-recorder">
//     <input type="file" name="visit[audio_note]" data-audio-recorder-target="fileInput" hidden>
//     <button data-action="click->audio-recorder#toggle" data-audio-recorder-target="recordButton">Record</button>
//     <span data-audio-recorder-target="timer">0:00</span>
//     <div data-audio-recorder-target="preview" hidden>
//       <audio controls data-audio-recorder-target="player"></audio>
//       <button data-action="click->audio-recorder#discard">Remove</button>
//     </div>
//   </div>

export default class extends Controller {
  static targets = ["fileInput", "recordButton", "timer", "preview", "player", "pauseButton"]

  connect() {
    this._chunks   = []
    this._recorder = null
    this._stream   = null
    this._startMs  = 0
    this._elapsed  = 0
    this._timerInterval = null
  }

  disconnect() {
    this._teardownRecorder()
  }

  async toggle() {
    if (this._recorder && this._recorder.state !== "inactive") {
      this._stop()
    } else {
      await this._start()
    }
  }

  togglePause() {
    if (!this._recorder) return
    if (this._recorder.state === "recording") {
      this._recorder.pause()
      this._stopTimer()
      this._paintRecord("paused")
    } else if (this._recorder.state === "paused") {
      this._recorder.resume()
      this._startTimer()
      this._paintRecord("recording")
    }
  }

  discard() {
    this._teardownRecorder()
    if (this.hasFileInputTarget) {
      // Reset by replacing — clearing .files isn't supported in all browsers.
      this.fileInputTarget.value = ""
    }
    if (this.hasPlayerTarget) {
      const oldUrl = this.playerTarget.dataset.objectUrl
      if (oldUrl) URL.revokeObjectURL(oldUrl)
      this.playerTarget.removeAttribute("src")
      this.playerTarget.dataset.objectUrl = ""
    }
    if (this.hasPreviewTarget) this.previewTarget.hidden = true
    this._elapsed = 0
    if (this.hasTimerTarget) this.timerTarget.textContent = ""
    this._paintRecord("idle")
  }

  // ── internals ────────────────────────────────────────────────────

  async _start() {
    try {
      this._stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (err) {
      console.warn("[audio-recorder] microphone permission denied:", err)
      if (this.hasRecordButtonTarget) this.recordButtonTarget.title = "Microphone access denied"
      return
    }

    this._chunks = []
    const mime = this._pickMimeType()
    this._recorder = mime ? new MediaRecorder(this._stream, { mimeType: mime }) : new MediaRecorder(this._stream)

    this._recorder.ondataavailable = (e) => { if (e.data && e.data.size > 0) this._chunks.push(e.data) }
    this._recorder.onstop = () => this._finalize()

    this._recorder.start(1000)  // emit a chunk every second so we don't lose audio if the tab crashes
    this._elapsed = 0
    this._startTimer()
    this._paintRecord("recording")
    if (this.hasPreviewTarget) this.previewTarget.hidden = true
  }

  _stop() {
    if (!this._recorder) return
    try { this._recorder.stop() } catch (_) {}
    this._stopTimer()
  }

  _finalize() {
    const type = this._recorder.mimeType || "audio/webm"
    const blob = new Blob(this._chunks, { type })
    const ext  = type.includes("ogg") ? "ogg" : (type.includes("mp4") ? "m4a" : "webm")
    const file = new File([blob], `visit-audio-${Date.now()}.${ext}`, { type })

    // Stuff the file into a real <input type=file> so Rails picks it up
    // through the normal form submit pathway (multipart) — no separate fetch.
    if (this.hasFileInputTarget) {
      const dt = new DataTransfer()
      dt.items.add(file)
      this.fileInputTarget.files = dt.files
    }

    if (this.hasPlayerTarget) {
      const url = URL.createObjectURL(blob)
      this.playerTarget.src = url
      this.playerTarget.dataset.objectUrl = url
    }
    if (this.hasPreviewTarget) this.previewTarget.hidden = false

    this._teardownStream()
    this._paintRecord("idle")
  }

  _teardownRecorder() {
    if (this._recorder && this._recorder.state !== "inactive") {
      try { this._recorder.stop() } catch (_) {}
    }
    this._stopTimer()
    this._teardownStream()
  }

  _teardownStream() {
    if (this._stream) {
      this._stream.getTracks().forEach((t) => { try { t.stop() } catch (_) {} })
      this._stream = null
    }
  }

  _startTimer() {
    this._startMs = Date.now() - this._elapsed
    if (this._timerInterval) clearInterval(this._timerInterval)
    this._timerInterval = setInterval(() => {
      this._elapsed = Date.now() - this._startMs
      if (this.hasTimerTarget) this.timerTarget.textContent = this._formatElapsed(this._elapsed)
    }, 250)
  }

  _stopTimer() {
    if (this._timerInterval) {
      clearInterval(this._timerInterval)
      this._timerInterval = null
    }
  }

  _formatElapsed(ms) {
    const totalSec = Math.floor(ms / 1000)
    const m = Math.floor(totalSec / 60)
    const s = totalSec % 60
    return `${m}:${String(s).padStart(2, "0")}`
  }

  _paintRecord(state) {
    if (!this.hasRecordButtonTarget) return
    const btn  = this.recordButtonTarget
    const icon = btn.querySelector("i")
    btn.dataset.state = state
    if (state === "recording") {
      btn.classList.add("bg-[#C1403A]", "text-white", "animate-pulse")
      btn.classList.remove("bg-[#FBF9F5]", "text-[#C1403A]")
      if (icon) { icon.classList.remove("ri-voiceprint-line"); icon.classList.add("ri-stop-circle-line") }
    } else if (state === "paused") {
      btn.classList.remove("animate-pulse")
    } else {  // idle
      btn.classList.remove("bg-[#C1403A]", "text-white", "animate-pulse")
      btn.classList.add("bg-[#FBF9F5]", "text-[#C1403A]")
      if (icon) { icon.classList.remove("ri-stop-circle-line"); icon.classList.add("ri-voiceprint-line") }
    }
  }

  // Pick the most-compatible MIME type the browser will agree to record.
  // Safari prefers mp4, Chrome/Firefox prefer webm/opus.
  _pickMimeType() {
    const candidates = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]
    return candidates.find((c) => typeof MediaRecorder !== "undefined" && MediaRecorder.isTypeSupported(c)) || ""
  }
}
