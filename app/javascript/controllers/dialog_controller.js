import { Controller } from "@hotwired/stimulus"

// Native <dialog> opener for per-card editing. The trigger lives in the
// card header; open() also expands the card (so the dialog is connected)
// and preventDefault stops the <summary> click from toggling the card.
export default class extends Controller {
  static targets = ["el"]

  open(e) {
    if (e) e.preventDefault()
    if (this.element.tagName === "DETAILS") this.element.open = true
    this.elTarget.showModal()
  }

  close(e) {
    if (e) e.preventDefault()
    this.elTarget.close()
  }

  // Close when the click lands on the backdrop (the dialog element itself),
  // not on its inner content.
  backdrop(e) {
    if (e.target === this.elTarget) this.elTarget.close()
  }
}
