import { Controller } from "@hotwired/stimulus"

// Re-renders "Overdue by Xh Ym" labels every 30 seconds so the
// dashboard's overdue-meds counter ticks forward without needing a
// full page reload. Each label carries data-since=<ISO timestamp>
// for the next-due-at moment; we compute the gap between now and
// then on every tick.
//
// Cleared on disconnect so navigating away doesn't leak intervals.
export default class extends Controller {
  static targets = ["overdueLabel"]

  connect() {
    this._tick()
    this._timer = setInterval(() => this._tick(), 30_000)
  }

  disconnect() {
    if (this._timer) { clearInterval(this._timer); this._timer = null }
  }

  _tick() {
    const now = Date.now()
    this.overdueLabelTargets.forEach((el) => {
      const since = el.dataset.since
      if (!since) return
      const due = Date.parse(since)
      if (Number.isNaN(due)) return
      const minsLate = Math.floor((now - due) / 60_000)
      if (minsLate <= 0) {
        el.textContent = "Due now"
      } else {
        el.textContent = `Overdue by ${this._fmt(minsLate)}`
      }
    })
  }

  _fmt(mins) {
    if (mins < 60) return `${mins}m`
    const h = Math.floor(mins / 60)
    const m = mins % 60
    return m === 0 ? `${h}h` : `${h}h ${m}m`
  }
}
