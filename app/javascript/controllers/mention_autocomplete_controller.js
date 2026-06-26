import { Controller } from "@hotwired/stimulus"

// Lightweight @-mention autocomplete for the chat composer. Types @, get a
// dropdown of @HosAlivio + the care team / clinicians; filter as you type;
// Arrow keys + Enter/Tab to pick; click to insert. No network — the pool is
// passed in via the items value (server-rendered, clinicians only).
export default class extends Controller {
  static targets = ["input", "menu"]
  static values  = { items: Array }

  connect() {
    this._matches = []
    this._active  = -1
    this._range   = null
    this._onInput   = this._onInput.bind(this)
    this._onKeydown = this._onKeydown.bind(this)
    this._onBlur    = () => setTimeout(() => this._close(), 150)
    this.inputTarget.addEventListener("input", this._onInput)
    this.inputTarget.addEventListener("keydown", this._onKeydown)
    this.inputTarget.addEventListener("blur", this._onBlur)
    // mousedown (not click) so we insert before the input's blur closes us.
    this.menuTarget.addEventListener("mousedown", (e) => {
      const li = e.target.closest("[data-mention-index]")
      if (!li) return
      e.preventDefault()
      this._select(Number(li.dataset.mentionIndex))
    })
  }

  disconnect() {
    this.inputTarget.removeEventListener("input", this._onInput)
    this.inputTarget.removeEventListener("keydown", this._onKeydown)
    this.inputTarget.removeEventListener("blur", this._onBlur)
  }

  // @HosAlivio is always first; then the server-provided people.
  get _pool() {
    return [{ handle: "HosAlivio", name: "HosAlivio", role: "AI", ai: true }, ...this.itemsValue]
  }

  // Is the caret right after an @handle token? Returns {query, start, end}.
  _detectQuery() {
    const el = this.inputTarget
    const pos = el.selectionStart
    const m = el.value.slice(0, pos).match(/(?:^|\s)@(\w*)$/)
    if (!m) return null
    return { query: m[1], start: pos - m[1].length - 1, end: pos }
  }

  _onInput() {
    const ctx = this._detectQuery()
    if (!ctx) return this._close()
    this._range = ctx
    const q = ctx.query.toLowerCase()
    this._matches = this._pool
      .filter((p) => !q || p.handle.toLowerCase().startsWith(q) || p.name.toLowerCase().includes(q))
      .slice(0, 8)
    if (this._matches.length === 0) return this._close()
    this._active = 0
    this._render()
  }

  _onKeydown(e) {
    if (this.menuTarget.classList.contains("hidden")) return
    if (e.key === "ArrowDown")      { e.preventDefault(); this._move(1) }
    else if (e.key === "ArrowUp")   { e.preventDefault(); this._move(-1) }
    else if (e.key === "Enter" || e.key === "Tab") { e.preventDefault(); this._select(this._active) }
    else if (e.key === "Escape")    { e.preventDefault(); this._close() }
  }

  _move(d) {
    this._active = (this._active + d + this._matches.length) % this._matches.length
    this._render()
  }

  _select(i) {
    const pick = this._matches[i]
    if (!pick || !this._range) return this._close()
    const el = this.inputTarget
    const before = el.value.slice(0, this._range.start)
    const after  = el.value.slice(this._range.end)
    const insert = `@${pick.handle} `
    el.value = before + insert + after
    const caret = before.length + insert.length
    el.setSelectionRange(caret, caret)
    this._close()
    el.focus()
    el.dispatchEvent(new Event("input", { bubbles: true })) // refresh placeholder, etc.
  }

  _render() {
    const esc = (s) => String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    this.menuTarget.innerHTML = this._matches.map((p, i) => {
      const badge = p.ai
        ? `<span class="w-6 h-6 rounded-full bg-[#D97757] text-white flex items-center justify-center flex-shrink-0"><i class="ri-heart-pulse-line text-[12px]"></i></span>`
        : `<span class="w-6 h-6 rounded-full bg-[#EFECE6] text-[#6B665F] text-[10px] font-bold flex items-center justify-center flex-shrink-0">${esc((p.name || "").split(" ").map((w) => w[0]).slice(0, 2).join("").toUpperCase())}</span>`
      const role = p.role ? `<span class="text-[10px] text-[#6B665F] uppercase tracking-wide ml-1">${esc(p.role)}</span>` : ""
      return `<button type="button" data-mention-index="${i}"
        class="w-full flex items-center gap-2 px-3 py-1.5 text-left ${i === this._active ? "bg-[#FBF9F5]" : ""} hover:bg-[#FBF9F5]">
        ${badge}
        <span class="min-w-0 flex-1 truncate text-[13px] ${p.ai ? "font-semibold text-[#D97757]" : "text-[#1D1C1A]"}">@${esc(p.handle)}<span class="text-[#6B665F] font-normal"> · ${esc(p.name)}</span></span>${role}
      </button>`
    }).join("")
    this.menuTarget.classList.remove("hidden")
  }

  _close() {
    this.menuTarget.classList.add("hidden")
    this._matches = []
    this._active  = -1
    this._range   = null
  }
}
