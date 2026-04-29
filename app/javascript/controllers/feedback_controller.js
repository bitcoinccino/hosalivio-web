import { Controller } from "@hotwired/stimulus"

// Thumbs up / down widget on every AI-authored note. Thumbs-up POSTs
// immediately. Thumbs-down opens an inline reasons panel; the user
// picks from a checkbox set + optional free text and submits. The
// server stamps feedback_by + feedback_at + a Notification-friendly
// AgentEvent. Family viewers never see this widget.
export default class extends Controller {
  static targets = ["upButton", "downButton", "status", "reasonPanel", "reason", "notes"]
  static values = {
    url:    String,
    csrf:   String,
    score:  { type: Number, default: 0 }
  }

  thumbsUp(event) {
    event?.stopPropagation()
    if (this.scoreValue === 1) return this._post(0)  // toggle off
    this._post(1)
  }

  thumbsDown(event) {
    event?.stopPropagation()
    if (this.scoreValue === -1) return this._post(0)  // toggle off
    if (this.hasReasonPanelTarget) this.reasonPanelTarget.classList.remove("hidden")
  }

  cancel(event) {
    event?.stopPropagation()
    if (this.hasReasonPanelTarget) this.reasonPanelTarget.classList.add("hidden")
    if (this.hasNotesTarget) this.notesTarget.value = ""
    this.reasonTargets.forEach((cb) => { cb.checked = false })
  }

  submit(event) {
    event?.stopPropagation()
    const reasons = this.reasonTargets.filter((cb) => cb.checked).map((cb) => cb.value)
    const notes   = this.hasNotesTarget ? this.notesTarget.value.trim() : ""
    this._post(-1, { reasons, notes })
  }

  _post(score, extras = {}) {
    const body = new URLSearchParams()
    body.append("score", score)
    Array.from(extras.reasons || []).forEach((r) => body.append("reasons[]", r))
    if (extras.notes) body.append("notes", extras.notes)

    fetch(this.urlValue, {
      method: "POST",
      headers: {
        "Accept":       "application/json",
        "X-CSRF-Token": this.csrfValue,
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: body.toString()
    }).then((resp) => {
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`)
      this.scoreValue = score
      this._paint(score)
      if (this.hasReasonPanelTarget) this.reasonPanelTarget.classList.add("hidden")
      this._setStatus(score === 1 ? "Thanks" : score === -1 ? "Logged" : "Cleared")
    }).catch((err) => {
      console.error("[feedback] failed:", err)
      this._setStatus("Could not save", "#C1403A")
    })
  }

  _paint(score) {
    if (this.hasUpButtonTarget) {
      this.upButtonTarget.classList.toggle("text-[#2F6F4E]", score === 1)
      this.upButtonTarget.classList.toggle("bg-[#E6F0EE]", score === 1)
    }
    if (this.hasDownButtonTarget) {
      this.downButtonTarget.classList.toggle("text-[#C1403A]", score === -1)
      this.downButtonTarget.classList.toggle("bg-[#FFF3EC]", score === -1)
    }
  }

  _setStatus(text, color = "#6B665F") {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = text
    this.statusTarget.style.color = color
    setTimeout(() => {
      if (this.statusTarget.textContent === text) this.statusTarget.textContent = ""
    }, 2500)
  }
}
