import { Controller } from "@hotwired/stimulus"

// Live notification toast: fades in on connect, auto-dismisses after a few
// seconds, and tears down cleanly when clicked through or dismissed.
export default class extends Controller {
  static values = { ttl: { type: Number, default: 7000 } }

  connect() {
    // Next frame so the opacity/translate transition actually runs.
    requestAnimationFrame(() => {
      this.element.classList.remove("opacity-0", "translate-y-1")
    })
    this.timer = setTimeout(() => this.dismiss(), this.ttlValue)
  }

  disconnect() {
    if (this.timer) clearTimeout(this.timer)
  }

  // Navigating away — let the link proceed, just stop the auto-dismiss timer.
  open() {
    if (this.timer) clearTimeout(this.timer)
  }

  dismiss() {
    if (this.timer) clearTimeout(this.timer)
    this.element.classList.add("opacity-0", "translate-y-1")
    setTimeout(() => this.element.remove(), 300)
  }
}
