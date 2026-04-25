import { Controller } from "@hotwired/stimulus"

// Tiny audience-switcher for the welcome-page FAQ. Two tabs (Family /
// Partner) flip a single data-audience attribute on the controller's
// root element; Tailwind group-data-[audience=...]/faq variants in the
// markup do the rest of the work — show one Q&A panel, hide the other.
export default class extends Controller {
  show(event) {
    const next = event.currentTarget.dataset.audience
    if (!next) return
    this.element.dataset.audience = next
  }
}
