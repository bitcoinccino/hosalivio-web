import { Controller } from "@hotwired/stimulus"

// Cookie notice with Accept / Reject. The choice is remembered in
// localStorage so the banner only shows until the visitor decides.
// "accepted" allows optional cookies (e.g. analytics); "rejected" keeps only
// the strictly-necessary ones.
export default class extends Controller {
  static values = { key: { type: String, default: "cookieConsent" } }

  connect() {
    if (this._decided()) this.element.remove()
  }

  accept() { this._save("accepted") }
  reject() { this._save("rejected") }

  _save(choice) {
    try { localStorage.setItem(this.keyValue, choice) } catch (_) { /* private mode */ }
    this.element.remove()
  }

  _decided() {
    try { return !!localStorage.getItem(this.keyValue) } catch (_) { return false }
  }
}
