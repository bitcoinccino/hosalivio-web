import { Controller } from "@hotwired/stimulus"

// Lightweight dropdown: toggle a panel, close on outside-click or ESC.
// Menu items add data-action="menu#close" to dismiss after acting.
export default class extends Controller {
  static targets = ["panel"]

  connect() {
    this._away = (e) => { if (!this.element.contains(e.target)) this.close() }
    this._esc  = (e) => { if (e.key === "Escape") this.close() }
    document.addEventListener("click", this._away)
    document.addEventListener("keydown", this._esc)
  }

  disconnect() {
    document.removeEventListener("click", this._away)
    document.removeEventListener("keydown", this._esc)
  }

  toggle(e) {
    e.stopPropagation()
    this.panelTarget.classList.toggle("hidden")
  }

  close() {
    this.panelTarget.classList.add("hidden")
  }
}
