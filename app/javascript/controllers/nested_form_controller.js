import { Controller } from "@hotwired/stimulus"

// Add / remove nested form rows (vitals, POC interventions, CS counts).
// Markup contract:
//   <div data-controller="nested-form">
//     <%# existing rows, each wrapped in [data-nested-form-row] with a hidden _destroy %>
//     <div data-nested-form-target="anchor"></div>
//     <template data-nested-form-target="template"> …fields_for child_index:"NEW_RECORD"… </template>
//     <button data-action="nested-form#add">Add</button>
//   </div>
export default class extends Controller {
  static targets = ["template", "anchor"]

  add(event) {
    event.preventDefault()
    const html = this.templateTarget.innerHTML.replaceAll("NEW_RECORD", Date.now().toString())
    this.anchorTarget.insertAdjacentHTML("beforebegin", html)
  }

  remove(event) {
    event.preventDefault()
    const row = event.target.closest("[data-nested-form-row]")
    if (!row) return
    const destroy = row.querySelector("input[name*='_destroy']")
    if (destroy) {        // persisted row → soft-delete on submit
      destroy.value = "1"
      row.classList.add("hidden")
    } else {              // brand-new unsaved row → just drop it
      row.remove()
    }
  }
}
