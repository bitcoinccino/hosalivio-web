import { Controller } from "@hotwired/stimulus"

// Instant, client-side filter for the Admissions queue. A search box matches
// patient name + diagnosis; status chips narrow to a group of statuses. Rows,
// their section headers, and an empty-state are toggled with no server round-trip.
export default class extends Controller {
  static targets = ["query", "row", "section", "chip", "empty"]

  connect() {
    const active = this.chipTargets.find((c) => c.dataset.on === "true") || this.chipTargets[0]
    this.groups = (active?.dataset.groups || "").split(",").filter(Boolean)
    this.apply()
  }

  status(event) {
    const chip = event.currentTarget
    this.groups = (chip.dataset.groups || "").split(",").filter(Boolean)
    this.chipTargets.forEach((c) => { c.dataset.on = (c === chip).toString() })
    this.apply()
  }

  filter() { this.apply() }

  apply() {
    const q = (this.hasQueryTarget ? this.queryTarget.value : "").trim().toLowerCase()
    let anyVisible = false

    this.rowTargets.forEach((row) => {
      const okGroup = this.groups.includes(row.dataset.status)
      const okText = !q || (row.dataset.search || "").includes(q)
      const show = okGroup && okText
      row.classList.toggle("hidden", !show)
      if (show) anyVisible = true
    })

    // Hide a section header once all its rows are filtered out.
    this.sectionTargets.forEach((sec) => {
      const shown = sec.querySelectorAll('[data-admissions-filter-target="row"]:not(.hidden)').length
      sec.classList.toggle("hidden", shown === 0)
    })

    if (this.hasEmptyTarget) this.emptyTarget.classList.toggle("hidden", anyVisible)
  }
}
