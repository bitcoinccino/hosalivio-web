import { Controller } from "@hotwired/stimulus"

// Long-form dictation for free-text areas (visit narratives, care plans).
// Uses the browser's Web Speech API — no external service, no API cost,
// no audio leaves the device. Works on Chrome, Edge, Safari (inc. iOS);
// unsupported on Firefox (no SpeechRecognition).
//
//   <div data-controller="dictation">
//     <textarea data-dictation-target="output"></textarea>
//     <button data-action="click->dictation#toggle"
//             data-dictation-target="button">
//       <i class="ri-mic-line"></i>
//     </button>
//     <span data-dictation-target="status"></span>
//   </div>
export default class extends Controller {
  static targets = ["output", "button", "status"]
  static values  = { lang: { type: String, default: "en-US" } }

  connect() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition
    if (!SR) {
      this._markUnsupported()
      return
    }

    const r = new SR()
    r.lang           = this.langValue
    r.interimResults = true
    r.continuous     = true     // keep listening across pauses

    r.onstart  = () => { this._setState("listening") }
    r.onend    = () => { this._setState("idle"); this._finalSnapshot() }
    r.onerror  = (e) => { this._setState("idle"); this._setStatus(`error: ${e.error}`, "#C1403A") }

    r.onresult = (e) => {
      let finalText   = this._baseline
      let interimText = ""
      for (let i = 0; i < e.results.length; i++) {
        const res = e.results[i]
        if (res.isFinal) finalText += res[0].transcript
        else             interimText += res[0].transcript
      }
      this._lastFinal = finalText
      this.outputTarget.value = (finalText + interimText).replace(/\s{2,}/g, " ").replace(/^\s+/, "")
    }

    this._speech   = r
    this._listening = false
    this._baseline  = this.outputTarget?.value || ""
    this._lastFinal = this._baseline
    this._markSupported()
  }

  disconnect() {
    try { this._speech?.stop() } catch (_) {}
  }

  toggle() {
    if (!this._speech) return
    if (this._listening) {
      this._speech.stop()
    } else {
      this._baseline = this.outputTarget.value ? this.outputTarget.value + " " : ""
      this._lastFinal = this._baseline
      try { this._speech.start() } catch (_) {}
    }
  }

  _finalSnapshot() {
    if (this._lastFinal) this.outputTarget.value = this._lastFinal
  }

  _setState(state) {
    this._listening = (state === "listening")
    if (!this.hasButtonTarget) return
    const icon = this.buttonTarget.querySelector("i")
    if (this._listening) {
      this.buttonTarget.classList.add("bg-[#C1403A]", "text-white", "animate-pulse")
      this.buttonTarget.classList.remove("bg-[#FBF9F5]", "text-[#D97757]")
      if (icon) { icon.classList.remove("ri-mic-line"); icon.classList.add("ri-mic-fill") }
      this._setStatus("Listening… tap again to stop", "#C1403A")
    } else {
      this.buttonTarget.classList.remove("bg-[#C1403A]", "text-white", "animate-pulse")
      this.buttonTarget.classList.add("bg-[#FBF9F5]", "text-[#D97757]")
      if (icon) { icon.classList.remove("ri-mic-fill"); icon.classList.add("ri-mic-line") }
      this._setStatus("", "#6B665F")
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
    this.buttonTarget.title = "Tap to dictate"
  }

  _markUnsupported() {
    if (!this.hasButtonTarget) return
    this.buttonTarget.disabled = true
    this.buttonTarget.title = "Voice dictation not supported in this browser"
    this.buttonTarget.classList.add("opacity-40", "cursor-not-allowed")
  }
}
