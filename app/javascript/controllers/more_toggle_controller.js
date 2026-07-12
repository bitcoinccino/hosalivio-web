import { Controller } from "@hotwired/stimulus"

// Reveals a hidden set of items when the toggle is clicked, and collapses
// them again. Label text is configurable via values so the same controller
// serves both the hero "View more" list and the modal's "Add more details".
export default class extends Controller {
  static targets = ["item", "label"]
  static values = {
    moreLabel: { type: String, default: "View more" },
    lessLabel: { type: String, default: "View less" }
  }

  toggle() {
    this.expanded = !this.expanded
    this.itemTargets.forEach((el) => el.classList.toggle("hidden", !this.expanded))
    if (this.hasLabelTarget) this.labelTarget.textContent = this.expanded ? this.lessLabelValue : this.moreLabelValue
    this.element.querySelector("[data-more-toggle-chevron]")?.classList.toggle("rotate-180", this.expanded)
  }
}
