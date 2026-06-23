import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["patient", "patientError", "serviceLocation", "facilityGroup", "facilityName"]
  static values = { scheduling: Boolean }

  connect() {
    this.syncFacility()
  }

  validate(event) {
    if (this.schedulingValue && this.hasPatientTarget && !this.patientTarget.value) {
      event.preventDefault()
      this.patientTarget.focus()
      this.patientTarget.setAttribute("aria-invalid", "true")
      if (this.hasPatientErrorTarget) {
        this.patientErrorTarget.textContent = "Pick a patient before scheduling this visit."
        this.patientErrorTarget.classList.remove("hidden")
      }
      return
    }

    if (this.hasPatientTarget) {
      this.patientTarget.removeAttribute("aria-invalid")
    }
  }

  patientChanged() {
    if (!this.hasPatientTarget || this.patientTarget.value) {
      if (this.hasPatientTarget) this.patientTarget.removeAttribute("aria-invalid")
      if (this.hasPatientErrorTarget) this.patientErrorTarget.classList.add("hidden")
    }
  }

  syncFacility() {
    if (!this.hasServiceLocationTarget || !this.hasFacilityGroupTarget) return

    const atHome = this.serviceLocationTarget.value === "home"
    this.facilityGroupTarget.classList.toggle("hidden", atHome)

    if (this.hasFacilityNameTarget) {
      this.facilityNameTarget.required = !atHome
      if (atHome) this.facilityNameTarget.value = ""
    }
  }
}
