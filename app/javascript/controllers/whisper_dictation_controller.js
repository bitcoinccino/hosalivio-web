import { Controller } from "@hotwired/stimulus"

// Whisper-backed dictation: records audio via MediaRecorder, uploads to
// /api/v1/transcribe, drops the transcript into the output target.
//
// Handles Haitian Creole, Spanish, Portuguese, Mandarin, etc. far better than
// the browser's Web Speech API. Falls back gracefully when the server has no
// OPENAI_API_KEY (the endpoint returns 503 with a hint; this controller surfaces
// it as a status message and does nothing further).
//
// Same target contract as dictation_controller, so it's a drop-in upgrade:
//   <div data-controller="whisper-dictation" data-whisper-dictation-lang-value="es">
//     <textarea data-whisper-dictation-target="output"></textarea>
//     <button data-action="click->whisper-dictation#toggle"
//             data-whisper-dictation-target="button"></button>
//     <span data-whisper-dictation-target="status"></span>
//   </div>
export default class extends Controller {
  static targets = ["output", "button", "status"]
  static values  = {
    lang:   { type: String, default: "" },
    prompt: { type: String, default: "" },
    url:    { type: String, default: "/api/v1/transcribe" }
  }

  connect() {
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === "undefined") {
      this._markUnsupported()
      return
    }
    this._recording = false
    this._chunks = []
    this._markSupported()
  }

  disconnect() {
    try { this._stopStream() } catch (_) {}
  }

  async toggle() {
    if (this._recording) {
      this._stop()
    } else {
      await this._start()
    }
  }

  async _start() {
    try {
      this._stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (err) {
      this._setStatus(`Microphone access denied`, "#C1403A")
      return
    }

    const mime = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
                 ? "audio/webm;codecs=opus"
                 : (MediaRecorder.isTypeSupported("audio/mp4") ? "audio/mp4" : "")

    this._recorder = new MediaRecorder(this._stream, mime ? { mimeType: mime } : {})
    this._chunks = []

    this._recorder.ondataavailable = (e) => { if (e.data?.size) this._chunks.push(e.data) }
    this._recorder.onstop = () => this._handleStop()

    this._recorder.start()
    this._recording = true
    this._paint(true)
    this._setStatus("Listening… tap to stop", "#C1403A")
  }

  _stop() {
    if (this._recorder && this._recording) {
      try { this._recorder.stop() } catch (_) {}
    }
    this._stopStream()
    this._recording = false
    this._paint(false)
    this._setStatus("Transcribing…", "#6B665F")
  }

  _stopStream() {
    try { this._stream?.getTracks().forEach((t) => t.stop()) } catch (_) {}
    this._stream = null
  }

  async _handleStop() {
    if (!this._chunks.length) {
      this._setStatus("", "#6B665F")
      return
    }
    const blob = new Blob(this._chunks, { type: this._recorder.mimeType || "audio/webm" })
    this._chunks = []

    const fd = new FormData()
    fd.append("audio", blob, `utterance.${this._extensionFor(blob.type)}`)
    if (this.langValue)   fd.append("language", this.langValue)
    if (this.promptValue) fd.append("prompt",   this.promptValue)

    const csrf = document.querySelector("meta[name='csrf-token']")?.content || ""

    try {
      const resp = await fetch(this.urlValue, {
        method:  "POST",
        headers: { "X-CSRF-Token": csrf, "Accept": "application/json" },
        body:    fd,
        credentials: "same-origin"
      })

      if (!resp.ok) {
        const data = await resp.json().catch(() => ({}))
        const code = data.error || `http_${resp.status}`
        const hint = data.hint  || "Voice transcription unavailable. Type instead."
        this._setStatus(hint, "#C1403A")
        console.warn("[whisper] error:", code, data)
        return
      }

      const data = await resp.json()
      const appended = (this.outputTarget.value ? this.outputTarget.value + " " : "") + data.text
      this.outputTarget.value = appended.replace(/\s{2,}/g, " ").trim()
      this._setStatus(`Transcribed (${Math.round(data.duration_seconds || 0)}s)`, "#2F6F4E")
      setTimeout(() => this._setStatus("", "#6B665F"), 3000)
    } catch (e) {
      this._setStatus("Transcription failed — type instead.", "#C1403A")
      console.warn("[whisper] exception:", e)
    }
  }

  _extensionFor(mime) {
    if (mime.includes("mp4"))  return "m4a"
    if (mime.includes("webm")) return "webm"
    return "bin"
  }

  _paint(on) {
    if (!this.hasButtonTarget) return
    const icon = this.buttonTarget.querySelector("i")
    if (on) {
      this.buttonTarget.classList.add("bg-[#C1403A]", "text-white", "animate-pulse")
      this.buttonTarget.classList.remove("bg-[#FBF9F5]", "text-[#D97757]")
      if (icon) { icon.classList.remove("ri-mic-line"); icon.classList.add("ri-mic-fill") }
    } else {
      this.buttonTarget.classList.remove("bg-[#C1403A]", "text-white", "animate-pulse")
      this.buttonTarget.classList.add("bg-[#FBF9F5]", "text-[#D97757]")
      if (icon) { icon.classList.remove("ri-mic-fill"); icon.classList.add("ri-mic-line") }
    }
  }

  _setStatus(text, color) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.style.color = color
  }

  _markSupported() {
    if (!this.hasButtonTarget) return
    this.buttonTarget.disabled = false
    this.buttonTarget.title = "Tap to dictate (high-accuracy, multilingual)"
  }

  _markUnsupported() {
    if (!this.hasButtonTarget) return
    this.buttonTarget.disabled = true
    this.buttonTarget.title = "Microphone not supported in this browser"
    this.buttonTarget.classList.add("opacity-40", "cursor-not-allowed")
  }
}
