import { Controller } from "@hotwired/stimulus"

// Calendar grid interactions:
//   - click an empty cell → navigate to /visits/new with user_id + scheduled_at pre-filled
//   - click a visit card → let the card's href run, do NOT bubble up to the cell handler
export default class extends Controller {
  newVisitForCell(event) {
    const { userId, scheduledAt, discipline } = event.currentTarget.dataset
    if (!userId || !scheduledAt) return
    const url = new URL("/visits/new", window.location.origin)
    url.searchParams.set("user_id", userId)
    url.searchParams.set("scheduled_at", scheduledAt)
    if (discipline) url.searchParams.set("discipline", discipline)
    window.location.href = url.toString()
  }

  stopPropagation(event) {
    event.stopPropagation()
  }
}
