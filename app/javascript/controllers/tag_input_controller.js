import { Controller } from "@hotwired/stimulus"

// Generic tag/chip input. Renders removable chips, each backed by a hidden
// array input (name="…[]"), so the form submits an array Rails normalizes.
//
// Add a tag with Enter / Tab / comma / paste; remove with × or Backspace on an
// empty field. Optional `pattern` validates each tag (invalid → brief flash).
// `spaceSeparated` (default true) splits input on whitespace too — turn it off
// for multi-word tags like county names ("Palm Beach").
export default class extends Controller {
  static targets = ["input", "chips"]
  static values  = { name: String, pattern: String, spaceSeparated: { type: Boolean, default: true } }

  connect() {
    this._re = this.patternValue ? new RegExp(this.patternValue) : null
  }

  keydown(e) {
    if (e.key === "Enter" || e.key === "Tab" || e.key === ",") {
      if (this.inputTarget.value.trim()) { e.preventDefault(); this.commit() }
    } else if (e.key === "Backspace" && !this.inputTarget.value) {
      this.removeLast()
    }
  }

  paste(e) {
    const text = (e.clipboardData || window.clipboardData).getData("text")
    if (this._separator().test(text)) {
      e.preventDefault()
      this._split(text).forEach((t) => this.add(t))
      this.inputTarget.value = ""
    }
  }

  blur() { if (this.inputTarget.value.trim()) this.commit() }

  commit() {
    this._split(this.inputTarget.value).forEach((t) => this.add(t))
    this.inputTarget.value = ""
    this.inputTarget.focus()
  }

  add(raw) {
    const val = (raw || "").trim()
    if (!val) return
    if (this._re && !this._re.test(val)) return this._flash()
    if (this._existing().includes(val)) return
    this.chipsTarget.appendChild(this._chip(val))
  }

  remove(e) {
    e.preventDefault()
    e.currentTarget.closest("[data-tag]").remove()
    this.inputTarget.focus()
  }

  removeLast() {
    const chips = this.chipsTarget.querySelectorAll("[data-tag]")
    if (chips.length) chips[chips.length - 1].remove()
  }

  // ── helpers ──
  _separator() { return this.spaceSeparatedValue ? /[\s,]+/ : /[,\n]+/ }
  _split(text) { return text.split(this._separator()) }
  _existing() { return Array.from(this.chipsTarget.querySelectorAll("input")).map((i) => i.value) }

  _chip(val) {
    const chip = document.createElement("span")
    chip.setAttribute("data-tag", "")
    chip.className = "inline-flex items-center gap-1 bg-[#EFECE6] text-[#1D1C1A] text-[13px] rounded-full pl-3 pr-1.5 py-1"

    const label = document.createElement("span")
    label.textContent = val

    const btn = document.createElement("button")
    btn.type = "button"
    btn.setAttribute("data-action", "tag-input#remove")
    btn.className = "w-4 h-4 rounded-full hover:bg-[#D9D5CD] flex items-center justify-center text-[#6B665F] leading-none"
    btn.textContent = "×"

    const hidden = document.createElement("input")
    hidden.type = "hidden"
    hidden.name = this.nameValue
    hidden.value = val

    chip.append(label, btn, hidden)
    return chip
  }

  _flash() {
    this.inputTarget.classList.add("ring-1", "ring-[#C1403A]", "rounded")
    setTimeout(() => this.inputTarget.classList.remove("ring-1", "ring-[#C1403A]", "rounded"), 600)
  }
}
