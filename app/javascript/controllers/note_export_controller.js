import { Controller } from "@hotwired/stimulus"

// Copy / download the visit note. text = the polished clinical narrative;
// json = the structured Medicaid eval payload (note + ICD-10 + LCD criteria).
// This is phase 1 of "sync to other software" — an external EMR push is a
// later drop-in that can POST the same json to a configured endpoint.
export default class extends Controller {
  static values = {
    text:     String,
    json:     String,
    filename: { type: String, default: "visit-note" }
  }

  copyText(event)  { this._copy(this.textValue, event?.currentTarget) }
  copyJson(event)  { this._copy(this.jsonValue, event?.currentTarget) }
  downloadTxt()    { this._download(this.textValue, `${this.filenameValue}.txt`,  "text/plain") }
  downloadJson()   { this._download(this.jsonValue, `${this.filenameValue}.json`, "application/json") }

  async _copy(text, btn) {
    const value = text || ""
    try {
      await navigator.clipboard.writeText(value)
      this._flash(btn, "Copied")
    } catch (_) {
      // Fallback for non-secure / older contexts.
      const ta = document.createElement("textarea")
      ta.value = value
      ta.style.position = "fixed"; ta.style.opacity = "0"
      document.body.appendChild(ta); ta.select()
      try { document.execCommand("copy"); this._flash(btn, "Copied") } catch (_) {}
      ta.remove()
    }
  }

  _download(content, name, mime) {
    const blob = new Blob([content || ""], { type: mime })
    const url  = URL.createObjectURL(blob)
    const a    = document.createElement("a")
    a.href = url; a.download = name
    document.body.appendChild(a); a.click(); a.remove()
    URL.revokeObjectURL(url)
  }

  _flash(btn, msg) {
    if (!btn) return
    const original = btn.innerHTML
    btn.innerHTML = `<i class="ri-check-line"></i> ${msg}`
    btn.disabled = true
    setTimeout(() => { btn.innerHTML = original; btn.disabled = false }, 1400)
  }
}
