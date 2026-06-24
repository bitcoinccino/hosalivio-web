import { Controller } from "@hotwired/stimulus"

// Drives a native <audio controls> element's playbackRate from pill buttons,
// since the browser player exposes no visible speed selector. Targets:
//   audio  — the <audio> element
//   button — each speed pill (carries data-rate="0.75|1|1.5|2")
export default class extends Controller {
  static targets = ["audio", "button"]

  connect() {
    this.rate = 1
    this._apply()
    // Browsers reset playbackRate when the media (re)loads — reassert ours.
    if (this.hasAudioTarget) {
      this._reassert = () => { this.audioTarget.playbackRate = this.rate }
      this.audioTarget.addEventListener("loadedmetadata", this._reassert)
    }
  }

  disconnect() {
    if (this.hasAudioTarget && this._reassert) {
      this.audioTarget.removeEventListener("loadedmetadata", this._reassert)
    }
  }

  setRate(event) {
    this.rate = parseFloat(event.currentTarget.dataset.rate)
    this._apply()
  }

  _apply() {
    if (this.hasAudioTarget) this.audioTarget.playbackRate = this.rate
    this.buttonTargets.forEach((b) => {
      const active = parseFloat(b.dataset.rate) === this.rate
      b.classList.toggle("bg-[#1D1C1A]", active)
      b.classList.toggle("text-white", active)
      b.classList.toggle("text-[#6B665F]", !active)
    })
  }
}
