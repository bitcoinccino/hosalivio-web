import { Controller } from "@hotwired/stimulus"

// Dim the optional charting sections when this is a facility / HA shift or an
// addendum is attached (those shifts chart less in-app). Purely visual — it
// doesn't disable inputs, just signals what's optional.
export default class extends Controller {
  static targets = ["toggle", "optional"]

  connect() { this.sync() }

  sync() {
    const relaxed = this.toggleTargets.some((t) => t.checked)
    this.optionalTargets.forEach((el) => el.classList.toggle("opacity-50", relaxed))
  }
}
