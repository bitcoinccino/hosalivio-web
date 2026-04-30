import { Controller } from "@hotwired/stimulus"

// Click any sentence to edit it inline; Enter or blur saves;
// Escape cancels. The full narrative is reassembled from the
// current sentence spans (paragraph-aware) and PATCHed to the
// configured URL.
//
// Targets:
//   sentence — each clickable sentence span (also receives the
//              click->inline-edit#edit action)
//   status   — caption showing Saving / Saved / Save failed
//
// Values:
//   url    — PATCH endpoint (e.g. /visits/:id)
//   field  — model attribute key under the wrapper param ("narrative")
//   locked — when true, clicks are no-ops (chart signed)
export default class extends Controller {
  static targets = ["sentence", "status"]
  static values  = {
    url:    String,
    field:  { type: String,  default: "narrative" },
    locked: { type: Boolean, default: false }
  }

  edit(event) {
    if (this.lockedValue) return
    if (this._editing) return
    event.preventDefault()

    const span = event.currentTarget
    const original = span.dataset.original ?? span.textContent

    const ta = document.createElement("textarea")
    ta.value = original
    ta.dataset.original = original
    ta.className = "w-full bg-[#FFF3EC] border border-[#D97757] rounded px-1.5 py-1 text-[14px] font-serif text-[#1D1C1A] leading-relaxed focus:outline-none focus:ring-2 focus:ring-[#D97757]"
    ta.rows = Math.max(1, Math.min(6, Math.ceil(original.length / 80)))

    span.replaceWith(ta)
    ta.focus()
    ta.setSelectionRange(0, ta.value.length)

    ta.addEventListener("blur",    () => this._commit(ta))
    ta.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.preventDefault()
        this._cancel(ta)
      } else if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault()
        this._commit(ta)
      }
    })

    this._editing = ta
  }

  async _commit(ta) {
    if (this._editing !== ta) return
    this._editing = null

    const original = ta.dataset.original
    const newValue = ta.value

    const span = this._spanFromValue(newValue)
    ta.replaceWith(span)

    if (newValue.trim() === original.trim()) return

    this._setStatus("Saving…")
    try {
      const body = JSON.stringify({ visit: { [this.fieldValue]: this._collectFullText() } })
      const resp = await fetch(this.urlValue, {
        method:  "PATCH",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": csrfToken()
        },
        body
      })
      if (!resp.ok) {
        const t = await resp.text().catch(() => "")
        throw new Error(`HTTP ${resp.status}: ${t.slice(0, 120)}`)
      }
      this._setStatus("Saved", "ok")
      setTimeout(() => this._setStatus(""), 2000)
    } catch (err) {
      console.error("Inline edit save failed:", err)
      this._setStatus("Save failed — try again", "err")
    }
  }

  _cancel(ta) {
    if (this._editing !== ta) return
    this._editing = null
    const span = this._spanFromValue(ta.dataset.original)
    ta.replaceWith(span)
  }

  _spanFromValue(value) {
    const span = document.createElement("span")
    span.dataset.inlineEditTarget = "sentence"
    span.dataset.action  = "click->inline-edit#edit"
    span.dataset.original = value
    span.title = this.lockedValue ? "Chart locked" : "Click to edit"
    span.className = this.lockedValue
      ? "px-0.5"
      : "cursor-text hover:bg-[#FFF3EC] hover:rounded px-0.5 transition"
    span.textContent = value
    return span
  }

  _collectFullText() {
    const paragraphs = this.element.querySelectorAll("p[data-paragraph]")
    if (paragraphs.length === 0) {
      return [...this.sentenceTargets].map(s => s.textContent.trim()).join(" ")
    }
    const parts = []
    paragraphs.forEach(p => {
      const sentences = [...p.querySelectorAll("[data-inline-edit-target='sentence']")]
        .map(s => s.textContent.trim())
        .filter(t => t.length > 0)
      if (sentences.length > 0) parts.push(sentences.join(" "))
    })
    return parts.join("\n\n")
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
