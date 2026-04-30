import { Controller } from "@hotwired/stimulus"

// Small interactive helpers on the profile Identity card:
//   - clicking the avatar triggers the hidden file input + auto-
//     submits when a new file is chosen so the upload feels
//     immediate (no Save click needed for the photo).
//   - phone input gets formatted to (XXX) XXX-XXXX as the user
//     types so messy paste-ins land clean.
//   - "Detect" reads the browser's resolved timezone and writes
//     it into the timezone select.
export default class extends Controller {
  static targets = ["fileInput", "phone", "timezone", "tzStatus"]

  pickPhoto() {
    if (this.hasFileInputTarget) this.fileInputTarget.click()
  }

  photoChosen() {
    if (!this.hasFileInputTarget) return
    if (!this.fileInputTarget.files || this.fileInputTarget.files.length === 0) return
    const form = this.element.closest("form")
    if (form) form.requestSubmit()
  }

  formatPhone() {
    if (!this.hasPhoneTarget) return
    const raw = this.phoneTarget.value.replace(/\D/g, "").slice(0, 10)
    let out = ""
    if (raw.length === 0)      out = ""
    else if (raw.length < 4)   out = `(${raw}`
    else if (raw.length < 7)   out = `(${raw.slice(0,3)}) ${raw.slice(3)}`
    else                       out = `(${raw.slice(0,3)}) ${raw.slice(3,6)}-${raw.slice(6)}`
    this.phoneTarget.value = out
  }

  detectTimezone() {
    if (!this.hasTimezoneTarget) return
    let detected
    try {
      detected = Intl.DateTimeFormat().resolvedOptions().timeZone
    } catch (_) {
      detected = null
    }
    if (!detected) {
      this._setTzStatus("Couldn't detect — pick from the list.", "err")
      return
    }
    const opt = [...this.timezoneTarget.options].find(o => o.value === detected)
    if (!opt) {
      this._setTzStatus(`Detected ${detected}, not in the list.`, "err")
      return
    }
    this.timezoneTarget.value = detected
    this._setTzStatus(`Set to ${detected}.`, "ok")
  }

  _setTzStatus(msg, kind) {
    if (!this.hasTzStatusTarget) return
    this.tzStatusTarget.textContent = msg
    this.tzStatusTarget.classList.remove("text-[#2F6F4E]", "text-[#C1403A]", "text-[#6B665F]")
    this.tzStatusTarget.classList.add(
      kind === "ok"  ? "text-[#2F6F4E]" :
      kind === "err" ? "text-[#C1403A]" : "text-[#6B665F]"
    )
  }
}
