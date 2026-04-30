import { Controller } from "@hotwired/stimulus"

// Partner ROI calculator. Two range sliders (team size + current
// turnover rate) feed a deterministic formula, the totals update
// live, and the "big reveal" headline at the bottom restates the
// outcome in one sentence. Numbers are calibrated to the static
// example above (10 nurses, 25% turnover → ~$359k/year).
//
// Targets:
//   teamInput, teamLabel, turnoverInput, turnoverLabel — slider rows
//   retention, efficiency, compliance, total — output cells
//   reveal — final headline copy
const REPLACE_COST_PER_RN = 40_000   // recruiting + onboarding for one RN
const TURNOVER_REDUCTION  = 0.30     // HosAlivio's claimed effect on the existing rate
const HOURS_PER_NURSE_YR  = 650      // charting (1.5h/day × 260) + triage (5h/wk × 52)
const HOURLY_RATE         = 95_000 / 2080   // $95k base / standard work-year hrs ≈ $45.67
const COMPLIANCE_PER_NURSE = 4_380   // ~$43,800 / 10-nurse baseline

export default class extends Controller {
  static targets = [
    "teamInput", "teamLabel",
    "turnoverInput", "turnoverLabel",
    "retention", "efficiency", "compliance", "total",
    "reveal"
  ]

  connect() { this.recompute() }

  recompute() {
    const team     = Math.max(1, parseInt(this.teamInputTarget.value, 10) || 1)
    const turnover = Math.max(0.01, (parseInt(this.turnoverInputTarget.value, 10) || 1) / 100)

    const retention  = Math.round(team * turnover * TURNOVER_REDUCTION * REPLACE_COST_PER_RN)
    const efficiency = Math.round(team * HOURS_PER_NURSE_YR * HOURLY_RATE)
    const compliance = Math.round(team * COMPLIANCE_PER_NURSE)
    const total      = retention + efficiency + compliance

    this.teamLabelTarget.textContent     = `${team} clinician${team === 1 ? "" : "s"}`
    this.turnoverLabelTarget.textContent = `${Math.round(turnover * 100)}% turnover`

    this.retentionTarget.textContent  = fmt(retention)
    this.efficiencyTarget.textContent = fmt(efficiency)
    this.complianceTarget.textContent = fmt(compliance)
    this.totalTarget.textContent      = fmt(total)

    if (this.hasRevealTarget) {
      this.revealTarget.innerHTML =
        `HosAlivio could save you <strong class="text-[#2F6F4E]">${fmt(total)}</strong> per year while giving your nurses their weekends back.`
    }
  }
}

function fmt(n) {
  return "$" + Math.round(n).toLocaleString("en-US")
}
