import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.closeOnEscape = this.closeOnEscape.bind(this)
    document.addEventListener("keydown", this.closeOnEscape)
    this.previousBodyOverflow = document.body.style.overflow
    document.body.style.overflow = "hidden"
  }

  disconnect() {
    document.removeEventListener("keydown", this.closeOnEscape)
    document.body.style.overflow = this.previousBodyOverflow || ""
  }

  close(event) {
    if (event) event.preventDefault()
    document.body.style.overflow = this.previousBodyOverflow || ""
    const frame = this.element.closest("turbo-frame")
    if (frame) {
      frame.innerHTML = ""
      frame.removeAttribute("src")
    } else {
      this.element.remove()
    }
  }

  closeFromBackdrop(event) {
    if (event.target === event.currentTarget) this.close(event)
  }

  closeOnEscape(event) {
    if (event.key === "Escape") this.close(event)
  }
}
