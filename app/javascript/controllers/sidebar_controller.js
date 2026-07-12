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
    this._sync = this._sync.bind(this)
    this._sync()
    // Re-evaluate on rotate/resize so crossing the md breakpoint can't strand
    // the sidebar in a collapsed rail while it's a full-screen mobile overlay.
    window.addEventListener("resize", this._sync)
  }

  disconnect() {
    window.removeEventListener("resize", this._sync)
  }

  // Desktop (>= md): collapse into an icon rail. Mobile: the sidebar is a
  // full-screen overlay, so the collapsed rail makes no sense.
  get isDesktop() {
    return window.matchMedia("(min-width: 768px)").matches
  }

  // Restore the saved preference on desktop; always expand on mobile (without
  // clobbering the saved desktop preference).
  _sync() {
    if (this.isDesktop) {
      this.sidebarTarget.dataset.collapsed =
        localStorage.getItem(this.storageKeyValue) === "1" ? "true" : "false"
    } else {
      this.sidebarTarget.dataset.collapsed = "false"
    }
  }

  collapse() { if (this.isDesktop) this.apply(true) }
  expand()   { this.apply(false) }

  toggle() {
    if (!this.isDesktop) return // collapsing is a desktop-only affordance
    const current = this.sidebarTarget.dataset.collapsed === "true"
    this.apply(!current)
  }

  apply(collapsed) {
    this.sidebarTarget.dataset.collapsed = collapsed ? "true" : "false"
    localStorage.setItem(this.storageKeyValue, collapsed ? "1" : "0")
  }
}
