import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["zips", "counties", "zipPreview", "countyPreview", "zipHelp", "countyHelp"]

  connect() {
    this.refresh()
  }

  refresh() {
    this._renderZips()
    this._renderCounties()
  }

  _renderZips() {
    if (!this.hasZipsTarget || !this.hasZipPreviewTarget) return

    const items = this._items(this.zipsTarget.value)
    const invalid = items.filter((item) => !/^\d{3}$|^\d{5}$/.test(item))
    const valid = items.filter((item) => !invalid.includes(item))

    this.zipPreviewTarget.innerHTML = this._chips(valid, {
      empty: "No ZIP rules yet",
      className: "bg-[#E6F0EE] text-[#2F6F4E] border-[#C9DDD6]"
    })

    if (this.hasZipHelpTarget) {
      if (invalid.length > 0) {
        this.zipHelpTarget.textContent = `Fix ${invalid.length} invalid ZIP ${invalid.length === 1 ? "entry" : "entries"}: ${invalid.join(", ")}. Use 3 or 5 digits.`
        this.zipHelpTarget.classList.remove("text-[#6B665F]")
        this.zipHelpTarget.classList.add("text-[#C1403A]")
      } else {
        this.zipHelpTarget.textContent = valid.length === 0
          ? "Add exact 5-digit ZIPs or 3-digit prefixes. A prefix like 331 matches all 331xx ZIPs."
          : `${valid.length} ZIP ${valid.length === 1 ? "rule" : "rules"} will be used for admissions routing.`
        this.zipHelpTarget.classList.remove("text-[#C1403A]")
        this.zipHelpTarget.classList.add("text-[#6B665F]")
      }
    }
  }

  _renderCounties() {
    if (!this.hasCountiesTarget || !this.hasCountyPreviewTarget) return

    const items = this._items(this.countiesTarget.value)
    this.countyPreviewTarget.innerHTML = this._chips(items, {
      empty: "No counties yet",
      className: "bg-[#FFF3EC] text-[#9A5A3A] border-[#F1D0BE]"
    })

    if (this.hasCountyHelpTarget) {
      this.countyHelpTarget.textContent = items.length === 0
        ? "Add county names when ZIP coverage is broad or unclear."
        : `${items.length} ${items.length === 1 ? "county" : "counties"} will be used as a routing fallback.`
    }
  }

  _items(value) {
    return [...new Set(
      value
        .split(/[,\n]/)
        .map((item) => item.trim())
        .filter(Boolean)
    )]
  }

  _chips(items, { empty, className }) {
    if (items.length === 0) {
      return `<span class="text-[11px] text-[#8A8379]">${empty}</span>`
    }

    return items.map((item) => (
      `<span class="inline-flex items-center rounded-full border px-2 py-1 text-[11px] font-medium ${className}">${this._escape(item)}</span>`
    )).join("")
  }

  _escape(value) {
    const element = document.createElement("div")
    element.textContent = value
    return element.innerHTML
  }
}
