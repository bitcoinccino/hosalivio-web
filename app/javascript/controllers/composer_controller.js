import { Controller } from "@hotwired/stimulus"

// Mission Stage composer: the Ask HosAlivio input. The "+" menu's
// "Schedule a visit" / "Assign a Clinician" items call prefill(), dropping a
// starter prompt into the input. Team chat lives in the right-rail panel, which
// has its own composer + live thread.
export default class extends Controller {
  static targets = ["input"]

  // Drop a starter prompt into the input (from a "+" menu action), then park
  // the cursor at the end so the user can finish the sentence.
  prefill(event) {
    if (event) event.preventDefault()
    const prompt = event.currentTarget.dataset.prompt || ""
    this.inputTarget.value = prompt
    this.inputTarget.focus()
    this.inputTarget.setSelectionRange(prompt.length, prompt.length)
  }
}
