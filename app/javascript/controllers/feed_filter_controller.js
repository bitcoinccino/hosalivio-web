import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["button", "item", "day", "empty"]

  connect() {
    this.current = "all"
  }

  select(event) {
    this.current = event.params.value || "all"

    this.buttonTargets.forEach((button) => {
      button.dataset.active = button.dataset.feedFilterValueParam === this.current ? "true" : "false"
    })

    this.apply()
  }

  itemAdded() {
    this.apply()
  }

  apply() {
    let visibleCount = 0

    this.itemTargets.forEach((item) => {
      const category = item.dataset.feedCategory || "all"
      const hidden = this.current !== "all" && category !== this.current
      item.classList.toggle("hidden", hidden)
      if (!hidden) visibleCount += 1
    })

    this.syncDayLabels()

    if (this.hasEmptyTarget) {
      this.emptyTarget.classList.toggle("hidden", visibleCount > 0)
    }
  }

  syncDayLabels() {
    this.dayTargets.forEach((day) => {
      let next = day.nextElementSibling
      let hasVisibleItem = false

      while (next && !next.dataset.feedFilterTarget?.includes("day")) {
        if (next.dataset.feedFilterTarget?.includes("item") && !next.classList.contains("hidden")) {
          hasVisibleItem = true
          break
        }
        next = next.nextElementSibling
      }

      day.classList.toggle("hidden", !hasVisibleItem)
    })
  }
}
