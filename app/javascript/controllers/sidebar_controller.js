import { Controller } from "@hotwired/stimulus"

// Collapses a sidebar into an icon-only rail (not fully hidden).
// Persistence via localStorage keyed by storageKey value.
//
// Markup uses a data-collapsed="true|false" attribute on the sidebar so
// child elements can respond via Tailwind's group-data-[collapsed=true] variants.
//
//   <div data-controller="sidebar" data-sidebar-storage-key-value="dashboardSidebar">
//     <aside data-sidebar-target="sidebar" data-collapsed="false"
//            class="group/sb w-72 data-[collapsed=true]:w-16 ...">
//       <button data-action="click->sidebar#toggle">...</button>
//       <span class="group-data-[collapsed=true]/sb:hidden">Text hidden when collapsed</span>
//     </aside>
//   </div>
export default class extends Controller {
  static targets = ["sidebar"]
  static values  = { storageKey: { type: String, default: "sidebarCollapsed" } }

  connect() {
    if (localStorage.getItem(this.storageKeyValue) === "1") {
      this.apply(true)
    }
  }

  collapse() { this.apply(true) }
  expand()   { this.apply(false) }

  toggle() {
    const current = this.sidebarTarget.dataset.collapsed === "true"
    this.apply(!current)
  }

  apply(collapsed) {
    this.sidebarTarget.dataset.collapsed = collapsed ? "true" : "false"
    localStorage.setItem(this.storageKeyValue, collapsed ? "1" : "0")
  }
}
