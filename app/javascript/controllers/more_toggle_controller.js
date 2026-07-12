import { Controller } from "@hotwired/stimulus"

// Reveals a hidden set of items (the starter prompts past the top 5) when
// "View more" is clicked, and collapses them again on "View less".
export default class extends Controller {
  static targets = ["item", "button", "label"]

  toggle() {
    this.expanded = !this.expanded
    this.itemTargets.forEach((el) => el.classList.toggle("hidden", !this.expanded))
    if (this.hasLabelTarget) this.labelTarget.textContent = this.expanded ? "View less" : "View more"
    this.element.querySelector("[data-more-toggle-chevron]")?.classList.toggle("rotate-180", this.expanded)
  }
}
