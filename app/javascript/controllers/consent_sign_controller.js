import { Controller } from "@hotwired/stimulus"
import SignaturePad from "signature_pad"

// Inline patient/family consent signing pad + signer selection.
//
// Signer modes:
//   patient  — name auto-filled + read-only; representative fields hidden.
//   someone  — a representative signs. If the patient has linked family
//              records, a dropdown offers them (auto-fills name + role) plus
//              an "other" option; picking "other" (or no family on file) shows
//              the full manual fields. Authority-to-sign is a select, shown
//              whenever a representative signs.
//
// Targets: canvas, dataField, roleField (hidden signer_role), nameField,
//   relInput (signer_relationship), patientNote, someoneBlock, familySelect,
//   otherFields, roleSelect, patientBtn, someoneBtn.
export default class extends Controller {
  static targets = [
    "canvas", "dataField", "roleField", "nameField", "relInput",
    "patientNote", "someoneBlock", "familySelect", "otherFields", "roleSelect",
    "patientBtn", "someoneBtn"
  ]
  static values = { patientName: String }

  connect() {
    if (this.hasCanvasTarget) {
      this._resize = this._resizeCanvas.bind(this)
      this._resizeCanvas()
      this._pad = new SignaturePad(this.canvasTarget, {
        minWidth: 0.6, maxWidth: 2.2,
        backgroundColor: "rgba(255,255,255,1)", penColor: "#1D1C1A"
      })
      window.addEventListener("resize", this._resize)
    }
    this._mode("patient")
  }

  disconnect() {
    if (this._resize) window.removeEventListener("resize", this._resize)
  }

  clearPad() { if (this._pad) this._pad.clear() }

  // ── Signer selection ───────────────────────────────────────
  signerPatient() {
    this.roleFieldTarget.value = "patient"
    this._nameReadOnly(true, this.patientNameValue)
    this._hideOther()
    this._mode("patient")
  }

  signerSomeone() {
    this._mode("someone")
    if (this.hasFamilySelectTarget) {
      // Wait for a dropdown pick; keep the name locked until then.
      this.familySelectTarget.value = ""
      this.roleFieldTarget.value = ""
      this._nameReadOnly(true, "")
      this._hideOther()
    } else {
      this._showOther()   // no family on file → straight to manual fields
    }
  }

  // Dropdown pick: a known family member, or "other".
  familyChanged() {
    const val = this.familySelectTarget.value
    const opt = this.familySelectTarget.selectedOptions[0]
    if (val === "other") {
      this._showOther()
    } else if (opt && opt.dataset.name) {
      this.roleFieldTarget.value = opt.dataset.role || "other_family"
      if (this.hasRelInputTarget) this.relInputTarget.value = opt.dataset.rel || ""
      this._nameReadOnly(true, opt.dataset.name)
      this._hideOther()
    } else {
      this.roleFieldTarget.value = ""
      this._nameReadOnly(true, "")
      this._hideOther()
    }
  }

  // The manual relationship <select> writes into the hidden signer_role.
  roleSelectChanged() {
    if (this.hasRoleSelectTarget) this.roleFieldTarget.value = this.roleSelectTarget.value
  }

  // ── Submit guard — stamp the signature data URL ────────────
  submit(event) {
    if (!this._pad || this._pad.isEmpty()) {
      event.preventDefault()
      alert("Have the signer draw their signature on the pad before submitting.")
      return
    }
    if (this.hasDataFieldTarget) this.dataFieldTarget.value = this._pad.toDataURL("image/png")
  }

  // ── helpers ────────────────────────────────────────────────
  _mode(mode) {
    const isPatient = mode === "patient"
    if (this.hasPatientNoteTarget)  this.patientNoteTarget.classList.toggle("hidden", !isPatient)
    if (this.hasSomeoneBlockTarget) this.someoneBlockTarget.classList.toggle("hidden", isPatient)
    if (this.hasPatientBtnTarget)   this._activate(this.patientBtnTarget, isPatient)
    if (this.hasSomeoneBtnTarget)   this._activate(this.someoneBtnTarget, !isPatient)
  }

  _showOther() {
    if (this.hasOtherFieldsTarget) this.otherFieldsTarget.classList.remove("hidden")
    if (this.hasRoleSelectTarget)  this.roleFieldTarget.value = this.roleSelectTarget.value
    this._nameReadOnly(false, "")
  }

  _hideOther() {
    if (this.hasOtherFieldsTarget) this.otherFieldsTarget.classList.add("hidden")
  }

  // Set the name field's value + read-only state. Only overwrite the value
  // when it's a locked/derived name, so a typed "other" name isn't wiped.
  _nameReadOnly(locked, value) {
    if (!this.hasNameFieldTarget) return
    this.nameFieldTarget.readOnly = locked
    if (locked) {
      this.nameFieldTarget.value = value
    } else if (this.nameFieldTarget.value === this.patientNameValue) {
      this.nameFieldTarget.value = ""
    }
  }

  _activate(btn, on) {
    btn.classList.toggle("bg-white", on)
    btn.classList.toggle("shadow-sm", on)
    btn.classList.toggle("text-[#1D1C1A]", on)
    btn.classList.toggle("text-[#6B665F]", !on)
  }

  _resizeCanvas() {
    const canvas = this.canvasTarget
    const ratio  = window.devicePixelRatio || 1
    const rect   = canvas.getBoundingClientRect()
    canvas.width  = rect.width * ratio
    canvas.height = rect.height * ratio
    canvas.getContext("2d").scale(ratio, ratio)
    if (this._pad) this._pad.clear()
  }
}
