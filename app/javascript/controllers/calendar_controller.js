import { Controller } from "@hotwired/stimulus"

// Calendar grid interactions:
//   - click an empty cell → navigate to /visits/new with user_id + scheduled_at pre-filled
//   - click a visit card → let the card's href run, do NOT bubble up to the cell handler
export default class extends Controller {
  newVisitForCell(event) {
    // A click on a visit card (its <a>) must run its own handling — opening the
    // visit-modal Turbo Frame. We can't stopPropagation on the card (that also
    // hides the click from Turbo's document listener, forcing a full-page nav),
    // so instead the cell handler bails when the click landed on a link.
    if (event.target.closest("a[href]")) return
    const { userId, scheduledAt, discipline } = event.currentTarget.dataset
    if (!userId || !scheduledAt) return
    const url = new URL("/visits/new", window.location.origin)
    url.searchParams.set("user_id", userId)
    url.searchParams.set("scheduled_at", scheduledAt)
    if (discipline) url.searchParams.set("discipline", discipline)
    window.location.href = url.toString()
  }
}
