import { Controller } from "@hotwired/stimulus"

// Opens the browser print dialog (which offers "Save as PDF"). A CSP-safe,
// Turbo-friendly replacement for inline onclick="window.print()".
export default class extends Controller {
  now(event) {
    if (event) event.preventDefault()
    window.print()
  }
}
