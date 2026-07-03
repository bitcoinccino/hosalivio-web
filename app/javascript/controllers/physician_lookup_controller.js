import { Controller } from "@hotwired/stimulus"

// Resolves the attending physician's NPI from their typed name via
// /lookups/physician (Coding::Npi / NPPES). Fires on blur — not per keystroke —
// to respect the rate-limited external registry and its 3s timeout. The
// connector is dormant server-side unless NPI_LIVE_LOOKUP is set, so this simply
// reports "no single registry match" when it's off. Fills the NPI field only
// when it's empty, so a manually-entered NPI is never clobbered.
export default class extends Controller {
  static targets = ["name", "npi", "status"]
  static values  = { url: String }

  async resolve() {
    const name = this.nameTarget.value.trim()
    this._status("", "")
    if (name.split(/\s+/).filter(Boolean).length < 2) return

    const params = new URLSearchParams({ name })
    const state = this._field("patient[state]"); if (state) params.set("state", state)
    const zip   = this._field("patient[zip]");   if (zip)   params.set("zip", zip)

    this._status("Checking registry…", "text-[#6B665F]")
    try {
      const res  = await fetch(`${this.urlValue}?${params}`, { headers: { Accept: "application/json" } })
      const data = await res.json()
      if (data.found) {
        if (this.hasNpiTarget && !this.npiTarget.value) this.npiTarget.value = data.npi
        const detail = [data.credential, data.taxonomy].filter(Boolean).join(" · ")
        this._status(`NPI ${data.npi} resolved${detail ? " · " + detail : ""}`, "text-[#2F6F4E]")
      } else {
        this._status("No single registry match", "text-[#8C6A2F]")
      }
    } catch (_) {
      this._status("", "")
    }
  }

  _field(name) {
    const el = document.querySelector(`[name='${name}']`)
    return el ? el.value.trim() : ""
  }

  _status(text, colorClass) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.className = `text-[11px] mt-1 ${colorClass}`
  }
}
