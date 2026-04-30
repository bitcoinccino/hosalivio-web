import { Controller } from "@hotwired/stimulus"
import SignaturePad from "signature_pad"

// Profile signature pad. Drives the <canvas> + Clear / Save buttons
// on /profile/signature. signature_pad gives us velocity-aware
// stroke smoothing so a trackpad signature looks much less jagged
// than raw mouse events would. On Save we POST the data URL to
// PATCH /profile/signature, then swap to the "registered" preview.
//
// Targets:
//   canvas      — the drawing surface
//   clearButton — wipes the pad
//   saveButton  — POSTs the data URL
//   status      — small caption for save success / error
//   preview     — image element to refresh after save
export default class extends Controller {
  static targets = ["canvas", "clearButton", "saveButton", "status", "preview"]
  static values  = { url: String }

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
  }

  disconnect() {
    window.removeEventListener("resize", this._resize)
  }

  clear() {
    if (this._pad) this._pad.clear()
    this._setStatus("")
  }

  async save() {
    if (!this._pad || this._pad.isEmpty()) {
      this._setStatus("Draw your signature first.", "err")
      return
    }
    this._setStatus("Saving…")
    const dataUrl = this._pad.toDataURL("image/png")
    try {
      const resp = await fetch(this.urlValue, {
        method:  "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": csrfToken()
        },
        body: JSON.stringify({ user: { signature_data_url: dataUrl } })
      })
      if (!resp.ok) {
        const j = await resp.json().catch(() => ({}))
        throw new Error(j.error || `HTTP ${resp.status}`)
      }
      const j = await resp.json()
      this._setStatus("Signature saved.", "ok")
      if (this.hasPreviewTarget && j.signature_url) {
        this.previewTarget.src = j.signature_url + "?t=" + Date.now()
        this.previewTarget.classList.remove("hidden")
      }
    } catch (err) {
      console.error("Signature save failed:", err)
      this._setStatus(err.message || "Save failed — try again.", "err")
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
