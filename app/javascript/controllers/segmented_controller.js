import { Controller } from "@hotwired/stimulus"

// A segmented single-select: a row of buttons that write the chosen value into a
// hidden <input>, so the form submits exactly the same name/value a <select>
// would. A value that matches no button (e.g. a Pascal free-text extraction) is
// preserved on the hidden input and simply leaves every button unhighlighted.
//
//   <div data-controller="segmented">
//     <input type="hidden" name="…" value="Assist" data-segmented-target="input">
//     <button data-segmented-target="option" data-value="Independent"
//             data-action="segmented#select">Independent</button>
//     …
//   </div>
export default class extends Controller {
  static targets = ["input", "option"]

  // active vs. idle pill styling (kept in sync with the ERB base classes)
  static ON  = ["bg-[#2B4A7A]", "text-white", "border-[#2B4A7A]"]
  static OFF = ["bg-white", "text-[#1D1C1A]", "border-[#D9D5CD]"]

  connect() { this.refresh() }

  select(event) {
    event.preventDefault()
    this.inputTarget.value = event.currentTarget.dataset.value
    this.refresh()
  }

  refresh() {
    const current = this.inputTarget.value
    this.optionTargets.forEach((btn) => {
      const on = btn.dataset.value === current
      btn.setAttribute("aria-pressed", on ? "true" : "false")
      this.constructor.ON.forEach((c) => btn.classList.toggle(c, on))
      this.constructor.OFF.forEach((c) => btn.classList.toggle(c, !on))
    })
  }
}
