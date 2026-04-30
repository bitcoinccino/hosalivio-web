import { Controller } from "@hotwired/stimulus"
import SignaturePad from "signature_pad"

// Inline patient/family consent signing pad. Same signature_pad
// library the clinician profile pad uses, but instead of POSTing
// the data URL straight to a save endpoint we write it into a
// hidden form field at submit time so the canvas piggy-backs on
// the parent ConsentForm form (kind, signer_role, signer_name,
// etc.). Clear button wipes the pad. Toggle buttons swap the
// signer block between "patient" and "representative" modes.
//
// Targets:
//   canvas      — the drawing surface
//   dataField   — hidden input that carries the data URL on submit
//   patientFields  — block shown when signer is the patient
//   repFields      — block shown when signer is a representative
//   roleInput   — hidden role select that toggles
//   signerNameInput — pre-filled with the patient's name when "patient" mode
export default class extends Controller {
  static targets = ["canvas", "dataField", "patientFields", "repFields", "roleInput", "signerNameInput"]
  static values  = {
    patientName: String
  }

  connect() {
    if (!this.hasCanvasTarget) return
    this._resize = this._resizeCanvas.bind(this)
    this._resizeCanvas()
    this._pad = new SignaturePad(this.canvasTarget, {
      minWidth:        0.6,
      maxWidth:        2.2,
      backgroundColor: "rgba(255,255,255,1)",
      penColor:        "#1D1C1A"
    })
    window.addEventListener("resize", this._resize)
    this._applySignerMode(this._currentRole())
  }

  disconnect() {
    window.removeEventListener("resize", this._resize)
  }

  clearPad() {
    if (this._pad) this._pad.clear()
  }

  signerPatient() { this._setRole("patient") }
  signerRepresentative() {
    const cur = this._currentRole()
    this._setRole(cur === "patient" ? "son" : cur)
  }

  // Submit guard — write the dataURL into the hidden field so the
  // server sees it. If the canvas is empty, block submit and let
  // the user know.
  submit(event) {
    if (!this._pad || this._pad.isEmpty()) {
      event.preventDefault()
      alert("Have the signer draw their signature on the pad before submitting.")
      return
    }
    if (this.hasDataFieldTarget) {
      this.dataFieldTarget.value = this._pad.toDataURL("image/png")
    }
  }

  // ── helpers ────────────────────────────────────────────────
  _setRole(role) {
    if (this.hasRoleInputTarget) this.roleInputTarget.value = role
    this._applySignerMode(role)
  }

  _currentRole() {
    return this.hasRoleInputTarget ? this.roleInputTarget.value : "patient"
  }

  _applySignerMode(role) {
    const isPatient = role === "patient"
    if (this.hasPatientFieldsTarget) this.patientFieldsTarget.classList.toggle("hidden", !isPatient)
    if (this.hasRepFieldsTarget)     this.repFieldsTarget.classList.toggle("hidden", isPatient)
    if (this.hasSignerNameInputTarget) {
      if (isPatient) {
        this.signerNameInputTarget.value = this.patientNameValue
        this.signerNameInputTarget.readOnly = true
      } else {
        if (this.signerNameInputTarget.readOnly) {
          this.signerNameInputTarget.value = ""
          this.signerNameInputTarget.readOnly = false
        }
      }
    }
  }

  _resizeCanvas() {
    const canvas = this.canvasTarget
    const ratio  = window.devicePixelRatio || 1
    const rect   = canvas.getBoundingClientRect()
    canvas.width  = rect.width * ratio
    canvas.height = rect.height * ratio
    const ctx = canvas.getContext("2d")
    ctx.scale(ratio, ratio)
    if (this._pad) this._pad.clear()
  }
}
