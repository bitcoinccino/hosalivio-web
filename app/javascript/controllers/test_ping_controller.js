import { Controller } from "@hotwired/stimulus"

// Fires a "Test from HosAlivio" ping on a single notification
// channel so the clinician can verify the integration before going
// on-call. Reuses the OutboundPing queue, so the openclaw poller
// delivers within a minute. Inline status caption flips to green
// (queued) or red (channel disabled, missing contact, etc.).
//
// Targets:
//   button — the Test button (gets its label swapped while busy)
//   status — the inline caption next to the row
export default class extends Controller {
  static targets = ["button", "status"]
  static values  = { url: String, channel: String }

  async send(event) {
    event.preventDefault()
    const btn = this.hasButtonTarget ? this.buttonTarget : event.currentTarget
    const original = btn.textContent
    btn.disabled = true
    btn.textContent = "Sending…"
    this._setStatus("Queuing test…", null)

    try {
      const resp = await fetch(this.urlValue, {
        method:  "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": csrfToken()
        },
        body: JSON.stringify({ channel: this.channelValue })
      })
      const j = await resp.json().catch(() => ({}))
      if (!resp.ok) {
        this._setStatus(j.error || `HTTP ${resp.status}`, "err")
      } else {
        this._setStatus(j.message || "Test queued.", "ok")
      }
    } catch (err) {
      console.error("Test ping failed:", err)
      this._setStatus("Network error — try again.", "err")
    } finally {
      btn.disabled = false
      btn.textContent = original
    }
  }

  _setStatus(msg, kind) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent = msg
    this.statusTarget.classList.remove("text-[#2F6F4E]", "text-[#C1403A]", "text-[#6B665F]")
    this.statusTarget.classList.add(
      kind === "ok"  ? "text-[#2F6F4E]" :
      kind === "err" ? "text-[#C1403A]" : "text-[#6B665F]"
    )
  }
}

function csrfToken() {
  const m = document.querySelector("meta[name='csrf-token']")
  return m ? m.content : ""
}
