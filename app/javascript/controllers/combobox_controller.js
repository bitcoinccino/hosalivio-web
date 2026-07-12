import { Controller } from "@hotwired/stimulus"

// Searchable single-select combobox. A text input filters a list of options;
// picking one writes its value to a hidden field and submits the enclosing
// form. Options carry data-value, data-label, and data-search (the haystack).
//
//   <div data-controller="combobox">
//     <input type="hidden" name="user_id" data-combobox-target="value">
//     <input type="text"  data-combobox-target="input"
//            data-action="focus->combobox#open input->combobox#filter">
//     <div data-combobox-target="list" class="hidden">
//       <button data-combobox-target="option" data-value="…" data-label="…"
//               data-search="…" data-action="click->combobox#select">…</button>
//     </div>
//   </div>
export default class extends Controller {
  static targets = ["input", "value", "list", "option"]

  connect() {
    this._away = (e) => { if (!this.element.contains(e.target)) this.close() }
    document.addEventListener("click", this._away)
  }

  disconnect() {
    document.removeEventListener("click", this._away)
  }

  open() { this.listTarget.classList.remove("hidden") }
  close() { this.listTarget.classList.add("hidden") }

  filter() {
    const q = this.inputTarget.value.trim().toLowerCase()
    this.open()
    this.optionTargets.forEach((o) => {
      const hay = (o.dataset.search || "").toLowerCase()
      o.classList.toggle("hidden", q !== "" && !hay.includes(q))
    })
  }

  select(e) {
    const o = e.currentTarget
    this.valueTarget.value = o.dataset.value || ""
    this.inputTarget.value = o.dataset.label || ""
    this.close()
    this.element.closest("form")?.requestSubmit()
  }
}
