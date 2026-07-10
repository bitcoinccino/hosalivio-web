import { Controller } from "@hotwired/stimulus"

// Reveals the "Please specify" field on the Book-a-demo form when the
// referral source is "Other".
export default class extends Controller {
  static targets = ["source", "other"]

  connect() { this.toggle() }

  toggle() {
    if (!this.hasSourceTarget || !this.hasOtherTarget) return
    this.otherTarget.classList.toggle("hidden", this.sourceTarget.value !== "Other")
  }
}
