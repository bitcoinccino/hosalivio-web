import { Controller } from "@hotwired/stimulus"

// Predictive ICD-10 diagnosis lookup. Two modes:
//   mode: "single" — the visible input IS the form field. Picking a result
//                    writes "Description (CODE)" back into it.
//   mode: "tags"   — the visible input is a search box only. Picking a result
//                    adds a chip and appends "Description (CODE)" to a hidden
//                    field (semicolon-separated) so several diagnoses can be
//                    captured without comma-soup typing.
//
// Results come from GET /lookups/icd10?q= as [{ code, description }].
export default class extends Controller {
  static targets = ["input", "results", "hidden", "tags"]
  static values  = { url: String, mode: { type: String, default: "single" } }

  connect() {
    this.items = []
    this.active = -1
    this.selected = []        // tags mode: [{ code, description }]
    this._onDocClick = (e) => { if (!this.element.contains(e.target)) this._close() }
    document.addEventListener("click", this._onDocClick)
    if (this.modeValue === "tags") {
      this._rehydrate()
      this._renderTags()
    }
  }

  disconnect() {
    document.removeEventListener("click", this._onDocClick)
    clearTimeout(this._timer)
  }

  search() {
    clearTimeout(this._timer)
    const q = this.inputTarget.value.trim()
    if (q.length < 2) return this._close()
    this._timer = setTimeout(() => this._fetch(q), 200)
  }

  async _fetch(q) {
    try {
      const res = await fetch(`${this.urlValue}?q=${encodeURIComponent(q)}`, {
        headers: { "Accept": "application/json" }
      })
      if (!res.ok) return this._close()
      this.items = await res.json()
      this.active = -1
      this._render()
    } catch (_) {
      this._close()
    }
  }

  keydown(event) {
    if (this.items.length === 0) return
    if (event.key === "ArrowDown") {
      event.preventDefault()
      this.active = Math.min(this.active + 1, this.items.length - 1)
      this._render()
    } else if (event.key === "ArrowUp") {
      event.preventDefault()
      this.active = Math.max(this.active - 1, 0)
      this._render()
    } else if (event.key === "Enter") {
      if (this.active >= 0) {
        event.preventDefault()
        this._pick(this.items[this.active])
      }
    } else if (event.key === "Escape") {
      this._close()
    }
  }

  // Clicking a result row (event delegation from the results container).
  choose(event) {
    const row = event.target.closest("[data-index]")
    if (!row) return
    this._pick(this.items[Number(row.dataset.index)])
  }

  _pick(item) {
    if (!item) return
    const label = `${item.description} (${item.code})`
    if (this.modeValue === "tags") {
      if (!this.selected.some((s) => s.code === item.code)) {
        this.selected.push(item)
        this._syncHidden()
        this._renderTags()
      }
      this.inputTarget.value = ""
    } else {
      this.inputTarget.value = label
    }
    this._close()
    this.inputTarget.focus()
  }

  removeTag(event) {
    const code = event.params.code || event.target.closest("[data-code]")?.dataset.code
    if (!code) return
    this.selected = this.selected.filter((s) => s.code !== code)
    this._syncHidden()
    this._renderTags()
  }

  // Rebuild chips from a pre-filled hidden field (e.g. after a validation
  // re-render). Expects "Description (CODE); Description (CODE)".
  _rehydrate() {
    if (!this.hasHiddenTarget || this.hiddenTarget.value.trim() === "") return
    this.selected = this.hiddenTarget.value.split(";").map((part) => {
      const m = part.trim().match(/^(.*)\s+\(([^()]+)\)$/)
      return m ? { description: m[1].trim(), code: m[2].trim() } : null
    }).filter(Boolean)
  }

  _syncHidden() {
    if (this.hasHiddenTarget) {
      this.hiddenTarget.value = this.selected.map((s) => `${s.description} (${s.code})`).join("; ")
    }
  }

  _render() {
    if (this.items.length === 0) return this._close()
    this.resultsTarget.innerHTML = this.items.map((item, i) => `
      <button type="button" data-index="${i}"
        class="w-full text-left px-3 py-2 text-[13px] flex items-baseline gap-2 ${i === this.active ? "bg-[#FBEFE9]" : "hover:bg-[#FBF9F5]"}">
        <span class="font-mono text-[12px] text-[#C56A4B] shrink-0">${this._esc(item.code)}</span>
        <span class="text-[#1D1C1A]">${this._esc(item.description)}</span>
      </button>`).join("")
    this.resultsTarget.classList.remove("hidden")
  }

  _renderTags() {
    if (!this.hasTagsTarget) return
    if (this.selected.length === 0) {
      this.tagsTarget.innerHTML = ""
      return
    }
    this.tagsTarget.innerHTML = this.selected.map((s) => `
      <span class="inline-flex items-center gap-1 rounded-full border border-[#D7E3DD] bg-[#EAF2EE] px-2.5 py-1 text-[12px] text-[#2F6F4E]">
        <span class="font-mono text-[11px]">${this._esc(s.code)}</span>
        <span>${this._esc(s.description)}</span>
        <button type="button" class="text-[#2F6F4E]/60 hover:text-[#C1403A] ml-0.5"
          data-action="icd-autocomplete#removeTag" data-icd-autocomplete-code-param="${this._esc(s.code)}" aria-label="Remove">
          <i class="ri-close-line"></i>
        </button>
      </span>`).join("")
  }

  _close() {
    this.resultsTarget.classList.add("hidden")
    this.resultsTarget.innerHTML = ""
    this.items = []
    this.active = -1
  }

  _esc(value) {
    const el = document.createElement("div")
    el.textContent = value
    return el.innerHTML
  }
}
