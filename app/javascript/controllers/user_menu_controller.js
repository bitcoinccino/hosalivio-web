import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["panel"]

  connect() {
    this.boundDocumentClick = this.documentClick.bind(this)
    this.boundEscape = this.escape.bind(this)
  }

  toggle(event) {
    event.stopPropagation()
    if (this.panelTarget.classList.contains("hidden")) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.panelTarget.classList.remove("hidden")
    document.addEventListener("click", this.boundDocumentClick)
    document.addEventListener("keydown", this.boundEscape)
  }

  close() {
    this.panelTarget.classList.add("hidden")
    document.removeEventListener("click", this.boundDocumentClick)
    document.removeEventListener("keydown", this.boundEscape)
  }

  documentClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  escape(event) {
    if (event.key === "Escape") this.close()
  }

  disconnect() {
    document.removeEventListener("click", this.boundDocumentClick)
    document.removeEventListener("keydown", this.boundEscape)
  }
}
