import { Controller } from "@hotwired/stimulus"

// Drives the admissions form's stacked collapsible sections: live age from DOB,
// "same phone as patient" copy, ZIP -> city/state autofill + suggested branch,
// dynamic reveal of religion / veteran detail, code-status color coding, and
// expand/collapse-all of the <details> sections.
export default class extends Controller {
  static targets = [
    "section",
    "dob", "age",
    "patientPhone", "caregiverPhone",
    "zip", "city", "state", "branchHint", "branchId",
    "codeStatus", "religionReveal", "veteranReveal"
  ]
  static values = { zipUrl: String }

  connect() {
    this.updateAge()
    this.colorCodeStatus()
    this.toggleReligion()
    this.toggleVeteran()
    // A required field inside a *closed* <details> can't be focused for native
    // validation ("not focusable" error). Open the offending section first.
    // `invalid` doesn't bubble, so listen in the capture phase.
    this._reveal = this._reveal.bind(this)
    this.element.addEventListener("invalid", this._reveal, true)
  }

  disconnect() {
    this.element.removeEventListener("invalid", this._reveal, true)
  }

  // ---- Collapsible sections ----------------------------------------------
  expandAll()   { this.sectionTargets.forEach((s) => (s.open = true)) }
  collapseAll() { this.sectionTargets.forEach((s) => (s.open = false)) }

  _reveal(event) {
    const details = event.target.closest("details")
    if (details) details.open = true
  }

  // ---- Live age from DOB --------------------------------------------------
  updateAge() {
    if (!this.hasDobTarget || !this.hasAgeTarget) return
    const value = this.dobTarget.value
    if (!value) { this.ageTarget.textContent = ""; return }
    const dob = new Date(value)
    if (isNaN(dob)) { this.ageTarget.textContent = ""; return }
    const now = new Date()
    let age = now.getFullYear() - dob.getFullYear()
    const m = now.getMonth() - dob.getMonth()
    if (m < 0 || (m === 0 && now.getDate() < dob.getDate())) age--
    this.ageTarget.textContent = age >= 0 && age < 130 ? `${age} yrs` : ""
  }

  // ---- Same phone as patient ---------------------------------------------
  toggleSamePhone(event) {
    if (!this.hasCaregiverPhoneTarget || !this.hasPatientPhoneTarget) return
    if (event.target.checked) {
      this.caregiverPhoneTarget.value = this.patientPhoneTarget.value
      this.caregiverPhoneTarget.readOnly = true
      this.caregiverPhoneTarget.classList.add("opacity-60", "bg-[#F1EEE8]")
    } else {
      this.caregiverPhoneTarget.readOnly = false
      this.caregiverPhoneTarget.classList.remove("opacity-60", "bg-[#F1EEE8]")
    }
  }

  // ---- ZIP -> city/state + branch ----------------------------------------
  async lookupZip() {
    if (!this.hasZipTarget) return
    const zip = this.zipTarget.value.replace(/\D/g, "").slice(0, 5)
    if (zip.length !== 5) return
    try {
      const res = await fetch(`${this.zipUrlValue}/${zip}`, { headers: { "Accept": "application/json" } })
      if (!res.ok) { this._branch(null); return }
      const data = await res.json()
      if (this.hasCityTarget && !this.cityTarget.value) this.cityTarget.value = data.city || ""
      if (this.hasStateTarget && !this.stateTarget.value) this.stateTarget.value = data.state || ""
      this._branch(data.branch)
    } catch (_) {
      this._branch(null)
    }
  }

  _branch(branch) {
    if (this.hasBranchIdTarget) this.branchIdTarget.value = branch?.id || ""
    if (!this.hasBranchHintTarget) return
    if (!branch) {
      this.branchHintTarget.innerHTML = ""
      this.branchHintTarget.classList.add("hidden")
      return
    }
    const covers = branch.covers
    const icon = covers ? "ri-map-pin-2-line text-[#2F6F4E]" : "ri-information-line text-[#8C6A2F]"
    const label = covers
      ? `Routes to <strong>${this._esc(branch.name)}</strong>`
      : `No branch covers this ZIP — defaulting to <strong>${this._esc(branch.name)}</strong>`
    this.branchHintTarget.innerHTML = `<i class="${icon}"></i> ${label}`
    this.branchHintTarget.classList.remove("hidden")
  }

  // ---- Code-status color coding ------------------------------------------
  colorCodeStatus() {
    if (!this.hasCodeStatusTarget) return
    const v = this.codeStatusTarget.value
    const map = {
      full_code:    ["border-[#C1403A]", "bg-[#FFF3EC]", "text-[#9A2F2A]"],
      dnr:          ["border-[#2F6F4E]", "bg-[#EAF2EE]", "text-[#235c3e]"],
      dni:          ["border-[#2F6F4E]", "bg-[#EAF2EE]", "text-[#235c3e]"],
      dnr_dni:      ["border-[#2F6F4E]", "bg-[#EAF2EE]", "text-[#235c3e]"],
      comfort_only: ["border-[#2F6F4E]", "bg-[#EAF2EE]", "text-[#235c3e]"]
    }
    const all = Object.values(map).flat()
    this.codeStatusTarget.classList.remove(...all)
    this.codeStatusTarget.classList.add(...(map[v] || []))
  }

  // ---- Dynamic reveals ----------------------------------------------------
  toggleReligion(event) {
    if (!this.hasReligionRevealTarget) return
    const on = event ? event.target.checked : !this._isBlank(this.religionRevealTarget)
    this.religionRevealTarget.classList.toggle("hidden", !on)
  }

  toggleVeteran(event) {
    if (!this.hasVeteranRevealTarget) return
    const select = event ? event.target : this.element.querySelector("[name='patient[veteran_status]']")
    const isVet = select && /veteran/i.test(select.value) && !/not a veteran/i.test(select.value)
    this.veteranRevealTarget.classList.toggle("hidden", !isVet)
  }

  _isBlank(wrapper) {
    const input = wrapper.querySelector("input, select, textarea")
    return !input || input.value.trim() === ""
  }

  _esc(value) {
    const el = document.createElement("div")
    el.textContent = value
    return el.innerHTML
  }
}
