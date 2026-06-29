import { Controller } from "@hotwired/stimulus"

// On a POC intervention row: when the med source is a caregiver/HA, force the
// "Response to care" field to the legally-required phrase and lock it; a nurse
// source re-enables free entry.
export default class extends Controller {
  static targets = ["source", "response"]
  static values  = { phrase: { type: String, default: "Patient or Caregiver Indicated They Provided" } }

  connect() { this.toggle() }

  toggle() {
    if (!this.hasSourceTarget || !this.hasResponseTarget) return
    if (this.sourceTarget.value === "caregiver") {
      this.responseTarget.value = this.phraseValue
      this.responseTarget.readOnly = true
    } else {
      if (this.responseTarget.value === this.phraseValue) this.responseTarget.value = ""
      this.responseTarget.readOnly = false
    }
  }
}
