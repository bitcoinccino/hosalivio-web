import { Controller } from "@hotwired/stimulus"

// Three-way tab switcher used on the visit edit page to flip
// between Medicaid (structured eval doc), Team (conversational
// IDT narrative), and JSON (raw eval payload). Panes carry
// data-note-tabs-pane="medicaid|team|json"; buttons carry the
// same key plus data-note-tabs-target="button".
export default class extends Controller {
  static targets = ["pane", "button"]
  static values  = { active: { type: String, default: "medicaid" } }

  connect() {
    const initial = this.element.dataset.noteTabsInitial || this.activeValue
    this.show({ params: { pane: initial } })
  }

  show(event) {
    const pane = event?.params?.pane || event?.currentTarget?.dataset?.noteTabsPaneParam
    if (!pane) return
    this.activeValue = pane
    this.paneTargets.forEach(el => {
      el.classList.toggle("hidden", el.dataset.noteTabsPane !== pane)
    })
    this.buttonTargets.forEach(el => {
      const isActive = el.dataset.noteTabsPaneParam === pane
      el.classList.toggle("bg-white",         isActive)
      el.classList.toggle("text-[#1D1C1A]",   isActive)
      el.classList.toggle("shadow-sm",        isActive)
      el.classList.toggle("text-[#6B665F]",  !isActive)
    })
  }
}
