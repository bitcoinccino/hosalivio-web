import { Controller } from "@hotwired/stimulus"

// Parse a free-text clinical narrative for vitals + pain score and fill
// matching form fields. Client-side regex only — zero API cost, works today.
// LLM structuring can replace this behind the same UI later; keep the UX
// contract (button + targets) identical so nothing else needs to change.
//
//   <div data-controller="vitals-extractor">
//     <textarea data-vitals-extractor-target="narrative"></textarea>
//     <input data-vitals-extractor-target="painScore">
//     <input data-vitals-extractor-target="bp">
//     <input data-vitals-extractor-target="temp">
//     <input data-vitals-extractor-target="pulse">
//     <input data-vitals-extractor-target="resp">
//     <input data-vitals-extractor-target="o2">
//     <button data-action="click->vitals-extractor#extract">Auto-fill</button>
//     <span data-vitals-extractor-target="summary"></span>
//   </div>
export default class extends Controller {
  static targets = ["narrative", "painScore", "bp", "temp", "pulse", "resp", "o2", "summary"]
  static values  = { autoExtract: { type: Boolean, default: false } }

  // When the visit edit page lands with ?just_recorded=1, the ERB sets
  // data-vitals-extractor-auto-extract-value="true" on this controller's
  // root. We auto-fire the extraction once on connect so the RN sees
  // pre-filled vitals without having to tap the Auto-fill button.
  connect() {
    if (this.autoExtractValue) {
      // Defer to next tick so the form fields are mounted and visible
      // before we modify them.
      setTimeout(() => this.extract(), 0)
    }
  }

  extract() {
    const text = (this.narrativeTarget?.value || "").toLowerCase()
    if (!text.trim()) {
      this._summary("No narrative text to parse.", "#C1403A")
      return
    }
    const hits = []

    const bpMatch = text.match(/\b(\d{2,3})\s*\/\s*(\d{2,3})\b/)
    if (bpMatch && this.hasBpTarget) {
      const sys = parseInt(bpMatch[1], 10)
      const dia = parseInt(bpMatch[2], 10)
      if (sys >= 60 && sys <= 260 && dia >= 30 && dia <= 160) {
        this.bpTarget.value = `${sys}/${dia}`
        hits.push(`BP ${sys}/${dia}`)
      }
    }

    const tempMatch =
      text.match(/\btemp(?:erature)?\s*(?:of|at|:)?\s*(\d{2,3}(?:\.\d)?)/) ||
      text.match(/\b(\d{2,3}\.\d)\s*°?\s*f\b/)
    if (tempMatch && this.hasTempTarget) {
      const t = parseFloat(tempMatch[1])
      if (t >= 90 && t <= 108) {
        this.tempTarget.value = t.toString()
        hits.push(`Temp ${t}`)
      }
    }

    const pulseMatch = text.match(/\b(?:pulse|hr|heart rate)\s*(?:of|at|:)?\s*(\d{2,3})\b/)
    if (pulseMatch && this.hasPulseTarget) {
      const p = parseInt(pulseMatch[1], 10)
      if (p >= 30 && p <= 220) {
        this.pulseTarget.value = p.toString()
        hits.push(`HR ${p}`)
      }
    }

    const respMatch = text.match(/\b(?:resp|rr|respirations?|respiratory rate)\s*(?:of|at|:)?\s*(\d{1,2})\b/)
    if (respMatch && this.hasRespTarget) {
      const r = parseInt(respMatch[1], 10)
      if (r >= 5 && r <= 60) {
        this.respTarget.value = r.toString()
        hits.push(`RR ${r}`)
      }
    }

    const o2Match = text.match(/\b(?:spo2|o2 sat|oxygen|pulse ?ox|o2)\s*(?:of|at|:)?\s*(\d{2,3})\s*%?/)
    if (o2Match && this.hasO2Target) {
      const o2 = parseInt(o2Match[1], 10)
      if (o2 >= 50 && o2 <= 100) {
        this.o2Target.value = o2.toString()
        hits.push(`SpO2 ${o2}%`)
      }
    }

    const painMatch = text.match(/\bpain\s*(?:score|level|of|at|:)?\s*(\d{1,2})(?:\s*\/\s*10)?/)
    if (painMatch && this.hasPainScoreTarget) {
      const pain = parseInt(painMatch[1], 10)
      if (pain >= 0 && pain <= 10) {
        this.painScoreTarget.value = pain.toString()
        hits.push(`Pain ${pain}/10`)
      }
    }

    if (hits.length === 0) {
      this._summary("No vitals detected in the narrative. Enter them below.", "#6B665F")
    } else {
      this._summary(`Extracted: ${hits.join(" · ")}`, "#2F6F4E")
    }
  }

  _summary(text, color) {
    if (!this.hasSummaryTarget) return
    this.summaryTarget.textContent = text
    this.summaryTarget.style.color = color
  }
}
