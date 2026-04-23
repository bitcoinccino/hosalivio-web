import { Controller } from "@hotwired/stimulus"

// Mobile filter sheet for the landing page. Below md the filter sidebar is
// hidden by default; this controller opens it as a slide-in drawer on top
// of the content with a backdrop. Above md it does nothing — the sidebar
// is statically visible.
export default class extends Controller {
  static targets = ["panel", "backdrop"]

  connect() {
    this._closed()
    this._escHandler = (e) => { if (e.key === "Escape") this.close() }
  }

  open() {
    this.panelTarget.dataset.open = "true"
    this.backdropTarget.classList.remove("hidden")
    document.addEventListener("keydown", this._escHandler)
    document.body.style.overflow = "hidden"
  }

  close() {
    this.panelTarget.dataset.open = "false"
    this.backdropTarget.classList.add("hidden")
    document.removeEventListener("keydown", this._escHandler)
    document.body.style.overflow = ""
  }

  toggle() {
    this.panelTarget.dataset.open === "true" ? this.close() : this.open()
  }

  _closed() {
    if (this.hasPanelTarget) this.panelTarget.dataset.open = "false"
  }
}
