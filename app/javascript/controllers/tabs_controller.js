import { Controller } from "@hotwired/stimulus"

// Generic tab switcher: shows one pane at a time and marks the active tab.
// Panes stay in the DOM (just hidden) so anything live-subscribed inside a
// hidden pane — e.g. a team-chat Turbo stream — keeps receiving updates.
//
// Markup:
//   <div data-controller="tabs">
//     <button data-tabs-target="tab" data-action="tabs#show" data-tabs-index-param="0" data-on="true">…</button>
//     <div data-tabs-target="pane">…</div>
//     <div data-tabs-target="pane" class="hidden">…</div>
//   </div>
export default class extends Controller {
  static targets = ["tab", "pane"]

  show(event) {
    event?.preventDefault?.()
    const idx = Number(event.params?.index ?? event.currentTarget.dataset.tabsIndexParam ?? 0)
    this.paneTargets.forEach((p, i) => p.classList.toggle("hidden", i !== idx))
    this.tabTargets.forEach((t, i) => { t.dataset.on = (i === idx).toString() })
  }
}
