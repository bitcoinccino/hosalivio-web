import { Controller } from "@hotwired/stimulus"

// Collapse a dashboard card's body on small screens to cut mobile scrolling.
// The toggle button is mobile-only (md:hidden) and the body carries md:block,
// so on desktop the body is always shown regardless of collapsed state — even
// if a collapsed phone is rotated to a wide viewport. State is per-card and
// resets to expanded when a live turbo-stream replaces the card (acceptable —
// a fresh update is worth seeing).
export default class extends Controller {
  static targets = ["body", "chevron"]

  toggle() {
    const collapsed = this.bodyTarget.classList.toggle("hidden")
    this.element.dataset.collapsed = collapsed
    if (this.hasChevronTarget) {
      this.chevronTarget.classList.toggle("rotate-180", collapsed)
    }
  }
}
