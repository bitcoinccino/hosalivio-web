import { Controller } from "@hotwired/stimulus"

// Mobile bottom-tab switcher for the admin Mission Stage view.
//
// On desktop (>= md) the census sidebar + stage + activity feed all show at
// once, so this controller does nothing visible. On mobile, exactly one "tab"
// panel is active at a time via data-mobile-active="true|false" on each target
// so Tailwind variants can toggle layout.
//
// Tabs are identified by data-tab-name: "census", "stage", "activity".
// The center "stage" is the default and stays mounted; "census" and
// "activity" overlay it full-screen when their tab is tapped.
export default class extends Controller {
  static targets = ["tab", "button"]

  connect() {
    this.activeTab = "stage"
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
        el.dataset.mobileActive = (el.dataset.tabName === this.activeTab) ? "true" : "false"
      })
    }
  }
}
