import { Controller } from "@hotwired/stimulus"

// Shows/hides the "If other, specify" field based on the relationship select value.
export default class extends Controller {
  static targets = ["other"]

  toggleOther(event) {
    const selected = event.target.value
    this.otherTarget.classList.toggle("hidden", selected !== "other")
  }
}
