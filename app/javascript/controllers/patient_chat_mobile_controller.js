import { Controller } from "@hotwired/stimulus"

// Mobile bottom-tab switcher for the patient chat view.
//
// On desktop (>= md breakpoint) the sidebar + chat + rail all show at once,
// so this controller does nothing visible. On mobile, exactly one "tab" panel
// is active at a time, controlled by data-mobile-active="true|false" on each
// target so Tailwind variants can toggle layout.
//
// Tabs are identified by data-tab-name: "team", "chat", "details".
export default class extends Controller {
  static targets = ["tab", "button"]

  connect() {
    this.activeTab = "chat"
    this.render()
  }

  activate(event) {
    const name = event.currentTarget.dataset.tabName
    if (!name) return
    this.activeTab = name
    this.render()
  }

  render() {
    this.tabTargets.forEach((el) => {
      el.dataset.mobileActive = (el.dataset.tabName === this.activeTab) ? "true" : "false"
    })
    if (this.hasButtonTarget) {
      this.buttonTargets.forEach((el) => {
        const on = el.dataset.tabName === this.activeTab
        el.dataset.mobileActive = on ? "true" : "false"
      })
    }
  }
}
