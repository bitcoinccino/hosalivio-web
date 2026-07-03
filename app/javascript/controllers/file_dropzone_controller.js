import { Controller } from "@hotwired/stimulus"

// Drag-and-drop wrapper around a hidden <input type="file">. Clicking the zone
// or dropping a file selects it; the filename label updates. Single file, to
// match PatientDocument's has_one_attached :file.
export default class extends Controller {
  static targets = ["input", "label", "zone"]

  // Clicking the zone opens the picker. Guard against the programmatic click on
  // the (bubbling) hidden input, which would otherwise re-enter and loop.
  browse(event) {
    if (event && event.target === this.inputTarget) return
    this.inputTarget.click()
  }

  dragOver(event) {
    event.preventDefault()
    this._highlight(true)
  }

  dragLeave(event) {
    event.preventDefault()
    this._highlight(false)
  }

  drop(event) {
    event.preventDefault()
    this._highlight(false)
    const files = event.dataTransfer?.files
    if (files && files.length) {
      this.inputTarget.files = files
      this._render()
    }
  }

  selected() { this._render() }

  _render() {
    if (!this.hasLabelTarget) return
    const file = this.inputTarget.files?.[0]
    this.labelTarget.textContent = file ? file.name : ""
  }

  _highlight(on) {
    if (!this.hasZoneTarget) return
    this.zoneTarget.classList.toggle("border-[#D97757]", on)
    this.zoneTarget.classList.toggle("bg-[#FBF3EE]", on)
  }
}
