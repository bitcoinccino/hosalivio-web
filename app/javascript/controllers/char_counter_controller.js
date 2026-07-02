import { Controller } from "@hotwired/stimulus"

// Live "N/max" counter for a textarea/input.
//
//   <div data-controller="char-counter" data-char-counter-max-value="500">
//     <textarea maxlength="500" data-char-counter-target="field"
//               data-action="input->char-counter#update"></textarea>
//     <span data-char-counter-target="count"></span>
//   </div>
export default class extends Controller {
  static targets = ["field", "count"]
  static values  = { max: Number }

  connect() { this.update() }

  update() {
    const len = this.fieldTarget.value.length
    const max = this.maxValue || this.fieldTarget.maxLength
    this.countTarget.textContent = `${len}/${max}`
    this.countTarget.classList.toggle("text-[#C1403A]", max > 0 && len >= max)
  }
}
