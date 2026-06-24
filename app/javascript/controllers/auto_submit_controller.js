import { Controller } from "@hotwired/stimulus"

// Submits the form this controller is attached to. Wire a file/select input
// with `data-action="change->auto-submit#submit"` so picking a value uploads
// immediately, with no separate "Save" button.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }
}
