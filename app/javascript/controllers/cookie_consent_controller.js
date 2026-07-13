import { Controller } from "@hotwired/stimulus"

// Dismissible cookie notice. Once the visitor accepts, we remember it in
// localStorage and don't show the banner again.
export default class extends Controller {
  static values = { key: { type: String, default: "cookieConsent" } }

  connect() {
    if (this._accepted()) this.element.remove()
  }

  accept() {
    try { localStorage.setItem(this.keyValue, "1") } catch (_) { /* private mode */ }
    this.element.remove()
  }

  _accepted() {
    try { return localStorage.getItem(this.keyValue) === "1" } catch (_) { return false }
  }
}
