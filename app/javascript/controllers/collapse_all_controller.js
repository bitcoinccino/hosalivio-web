import { Controller } from "@hotwired/stimulus"

// Expand / collapse every [data-collapsible] <details> within scope.
// Inner disclosures (without data-collapsible) are left untouched.
export default class extends Controller {
  expandAll()   { this._all().forEach(d => (d.open = true)) }
  collapseAll() { this._all().forEach(d => (d.open = false)) }
  _all() { return this.element.querySelectorAll("details[data-collapsible]") }
}
