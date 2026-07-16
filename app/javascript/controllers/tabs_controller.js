import { Controller } from "@hotwired/stimulus"

// Generic tab switcher: shows one pane at a time and marks the active tab.
// Panes stay in the DOM (just hidden) so anything live-subscribed inside a
// hidden pane — e.g. a team-chat Turbo stream — keeps receiving updates.
//
// Markup:
//   <div data-controller="tabs" data-tabs-initial-value="1">
//     <button data-tabs-target="tab" data-action="tabs#show" data-tabs-index-param="0" data-on="true">…</button>
//     <div data-tabs-target="pane">…</div>
//     <div data-tabs-target="pane" class="hidden">…</div>
//   </div>
//
// `initial` (optional) opens that pane on load — used to deep-link the right
// rail to the Team-chat tab (and a channel) right after a dashboard post.
export default class extends Controller {
  static targets = ["tab", "pane"]
  static values = { initial: Number }

  connect() {
    if (this.hasInitialValue && this.initialValue > 0 && this.initialValue < this.paneTargets.length) {
      this.activate(this.initialValue)
    }
  }

  show(event) {
    event?.preventDefault?.()
    const idx = Number(event.params?.index ?? event.currentTarget.dataset.tabsIndexParam ?? 0)
    this.activate(idx)
  }

  activate(idx) {
    this.paneTargets.forEach((p, i) => p.classList.toggle("hidden", i !== idx))
    this.tabTargets.forEach((t, i) => { t.dataset.on = (i === idx).toString() })
  }
}
