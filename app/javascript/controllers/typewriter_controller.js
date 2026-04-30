import { Controller } from "@hotwired/stimulus"

// Self-writing tagline that loops between phrases. Types the
// current phrase one character at a time, holds, backspaces,
// types the next. Wraps to the start. Honors prefers-reduced-
// motion: users who opt out see the longest phrase rendered
// statically (no animation, no looping).
//
// Usage:
//   <h1 data-controller="typewriter"
//       data-typewriter-phrases-value='["Care that listens..","relief that lasts."]'
//       data-typewriter-speed-value="55"
//       data-typewriter-hold-value="1400"></h1>
export default class extends Controller {
  static values = {
    text:       { type: String, default: "" },
    phrases:    { type: Array,  default: [] },
    speed:      { type: Number, default: 45 },   // ms per character (typing)
    eraseSpeed: { type: Number, default: 30 },   // ms per character (backspacing)
    hold:       { type: Number, default: 1500 }, // ms to hold a fully-typed phrase before erasing
    pauseAfterErase: { type: Number, default: 250 }, // brief beat before next phrase
    startWait:  { type: Number, default: 200 }
  }

  connect() {
    this._phrases = this.phrasesValue.length > 0 ? this.phrasesValue : (this.textValue ? [this.textValue] : [])
    if (this._phrases.length === 0) return

    if (this._reducedMotion()) {
      this.element.textContent = this._phrases.reduce((a, b) => (b.length > a.length ? b : a), "")
      return
    }

    this.element.textContent = ""
    this._textNode = document.createTextNode("")
    this.element.appendChild(this._textNode)
    this._caret = document.createElement("span")
    this._caret.className = "inline-block w-[2px] h-[0.9em] align-[-0.05em] ml-0.5 bg-[#D97757] animate-pulse"
    this.element.appendChild(this._caret)

    this._phraseIdx = 0
    this._charIdx   = 0
    this._loopActive = true
    setTimeout(() => this._typeNext(), this.startWaitValue)
  }

  disconnect() {
    this._loopActive = false
  }

  // ── lifecycle ──────────────────────────────────────────────
  _typeNext() {
    if (!this._loopActive) return
    const phrase = this._phrases[this._phraseIdx]
    if (this._charIdx < phrase.length) {
      this._charIdx++
      this._textNode.data = phrase.slice(0, this._charIdx)
      setTimeout(() => this._typeNext(), this.speedValue)
    } else {
      // Hold then start erasing — unless this is the only phrase,
      // in which case stop after typing it once.
      if (this._phrases.length === 1) return
      setTimeout(() => this._eraseNext(), this.holdValue)
    }
  }

  _eraseNext() {
    if (!this._loopActive) return
    if (this._charIdx > 0) {
      this._charIdx--
      this._textNode.data = this._phrases[this._phraseIdx].slice(0, this._charIdx)
      setTimeout(() => this._eraseNext(), this.eraseSpeedValue)
    } else {
      this._phraseIdx = (this._phraseIdx + 1) % this._phrases.length
      setTimeout(() => this._typeNext(), this.pauseAfterEraseValue)
    }
  }

  _reducedMotion() {
    return window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches
  }
}
