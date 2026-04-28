import { Controller } from "@hotwired/stimulus"

// Two-way toggle between a "Human friendly" view and a raw JSON
// view of the same record. Used on the visit edit page so the RN
// can flip between the structured eval summary and the raw JSON
// dump without leaving the page. The two views are pre-rendered;
// this controller just swaps which one is hidden.
export default class extends Controller {
  static targets = ["human", "json", "humanButton", "jsonButton"]

  connect() {
    this._show("human")
  }

  showHuman() { this._show("human") }
  showJson()  { this._show("json")  }

  _show(which) {
    if (this.hasHumanTarget) this.humanTarget.classList.toggle("hidden", which !== "human")
    if (this.hasJsonTarget)  this.jsonTarget.classList.toggle("hidden",  which !== "json")
    if (this.hasHumanButtonTarget) this._setActive(this.humanButtonTarget, which === "human")
    if (this.hasJsonButtonTarget)  this._setActive(this.jsonButtonTarget,  which === "json")
  }

  _setActive(button, active) {
    if (active) {
      button.classList.remove("text-[#6B665F]", "bg-transparent")
      button.classList.add("bg-white", "text-[#1D1C1A]", "shadow-sm")
    } else {
      button.classList.remove("bg-white", "text-[#1D1C1A]", "shadow-sm")
      button.classList.add("text-[#6B665F]", "bg-transparent")
    }
  }
}
