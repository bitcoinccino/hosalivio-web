import { Controller } from "@hotwired/stimulus"

// Small dropdown popover anchored to the + button in the chat
// composer. Same UX as the sidebar profile menu: click the trigger
// to open, click outside or hit ESC to close.
//
// Markup contract:
//   <div data-controller="quick-actions">
//     <button data-action="click->quick-actions#toggle">+</button>
//     <%= render "quick_actions_dropdown" %>   ← contains data-quick-actions-target="panel"
//   </div>

export default class extends Controller {
  static targets = ["panel"]

  connect() {
    this.boundDocumentClick = this.documentClick.bind(this)
    this.boundEscape        = this.escape.bind(this)
  }

  toggle(event) {
    event.stopPropagation()
    if (this.panelTarget.classList.contains("hidden")) {
      this.open()
    } else {
      this.close()
    }
  }

  open() {
    this.panelTarget.classList.remove("hidden")
    document.addEventListener("click", this.boundDocumentClick)
    document.addEventListener("keydown", this.boundEscape)
  }

  close() {
    this.panelTarget.classList.add("hidden")
    document.removeEventListener("click", this.boundDocumentClick)
    document.removeEventListener("keydown", this.boundEscape)
  }

  documentClick(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  escape(event) {
    if (event.key === "Escape") this.close()
  }

  disconnect() {
    document.removeEventListener("click", this.boundDocumentClick)
    document.removeEventListener("keydown", this.boundEscape)
  }
}
