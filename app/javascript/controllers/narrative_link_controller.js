import { Controller } from "@hotwired/stimulus"

// When the RN highlights a word / phrase / paragraph in the polished
// note, find the closest matching span in the right-sidebar
// transcript, scroll it into view, and wrap it in <mark>. Also
// renders the transcript as turn-blocks (one block per speaker
// utterance) with per-speaker backgrounds, bolded medical terms,
// and supports a search box + speaker/keyword filter.
//
// Targets:
//   source      — note panes the RN selects from (Medicaid / Team)
//   transcript  — container the turn-blocks render into
//   status      — small caption updated on hit/miss (optional)
//   search      — text input that hides non-matching turns
//   count       — caption showing "N visible / M total"
//   filter      — buttons that switch between All / Patient / Clinician / Keywords
const STOP = new Set([
  "the","and","for","with","that","this","from","into","over","about",
  "then","than","they","them","but","not","are","was","has","have","had",
  "you","she","her","his","him","its","our","your","is","of","to","a",
  "an","in","on","at","by","as","be","or","it","we","i"
])

const PUNCT_RE = /[.,!?;:'"\(\)\[\]\-—]/g
const SPEAKER_RE_GLOBAL = /\[([^\]]+):\]/g

const MEDICAL_TERMS = [
  "comfort-focused", "comfort care", "code status", "advance directive",
  "hospice", "palliative", "DNR", "DNI", "POLST", "MOLST",
  "prognosis", "terminal", "eligibility", "eligible", "certification", "recertification",
  "shortness of breath", "weight loss", "pressure injury",
  "pain", "dyspnea", "edema", "nausea", "vomiting", "fatigue", "hemoptysis",
  "delirium", "confusion", "agitation", "anxiety", "depression",
  "constipation", "diarrhea", "incontinence", "anorexia", "cachexia", "ascites",
  "fever", "cough", "wheezing", "bleeding", "weakness", "tremor", "seizure",
  "headache", "dizziness", "wound", "ulcer", "fall", "falls",
  "metastatic", "myocardial infarction", "atrial fibrillation",
  "heart failure", "kidney disease", "renal failure", "liver disease",
  "cancer", "tumor", "metastasis", "malignancy", "carcinoma", "leukemia", "lymphoma",
  "COPD", "emphysema", "bronchitis", "asthma", "pneumonia",
  "CHF", "MI", "arrhythmia",
  "stroke", "CVA", "TIA", "dementia", "Alzheimer", "Parkinson", "ALS",
  "diabetes", "diabetic", "hypertension", "hyperlipidemia",
  "ESRD", "dialysis", "cirrhosis", "hepatitis",
  "blood pressure", "heart rate", "respiratory rate",
  "BP", "pulse", "temperature", "oxygen", "SpO2", "O2", "saturation",
  "MS Contin", "Ativan", "Haldol", "Versed", "Zofran", "Reglan", "Coumadin", "Tylenol",
  "morphine", "oxycodone", "hydromorphone", "fentanyl", "methadone",
  "lorazepam", "haloperidol", "midazolam",
  "dexamethasone", "prednisone",
  "ondansetron", "metoclopramide", "scopolamine", "atropine",
  "ibuprofen", "acetaminophen", "aspirin",
  "insulin", "metformin", "warfarin", "heparin",
  "oxygen concentrator", "nasal cannula", "hospital bed", "bedside commode",
  "Foley catheter", "PEG tube", "G-tube", "feeding tube",
  "walker", "wheelchair", "commode",
  "bathing", "dressing", "toileting", "transferring", "feeding", "continence", "ambulation",
  "registered nurse", "social worker", "RN", "MD", "physician", "chaplain", "aide", "CNA",
  "caregiver", "IDT", "interdisciplinary",
  "albumin", "creatinine", "GFR", "A1C", "PPS", "FAST", "Karnofsky"
]

const MEDICAL_RE = new RegExp(
  "\\b(?:" +
    MEDICAL_TERMS
      .sort((a, b) => b.length - a.length)
      .map(t => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\s+/g, "\\s+"))
      .join("|") +
  ")\\b",
  "gi"
)

const CLINICIAN_NAMES = new Set(["rn", "nurse", "clinician", "md", "doctor", "physician", "don", "aide", "chaplain", "social worker", "social_worker"])
const PATIENT_NAMES = new Set(["patient", "maria"])
const ROLE_TINTS = {
  clinician: { bg: "#FFF3EC", border: "#D97757" },
  patient:   { bg: "#E6F0EE", border: "#2F6F4E" },
  other:     { bg: "#FBF9F5", border: "#D9D5CD" }
}
const FALLBACK_PALETTE = ["#2B4A7A", "#7E3FAD", "#A8423E", "#1D1C1A", "#5C7A3E"]

export default class extends Controller {
  static targets = ["source", "transcript", "status", "search", "count", "filter"]
  static values  = { filter: { type: String, default: "all" } }

  connect() {
    if (this.hasTranscriptTarget) {
      const cached = this.transcriptTarget.dataset.transcriptText
      this._originalText = (cached != null ? cached : this.transcriptTarget.textContent) || ""
      this._roster = this._parseRoster()
      this._segments = this._parseSegments()
      this._turns = this._parseTurns(this._originalText)
      this._render()
      this._applyVisibility()
    }
    this._handler = this._onMouseUp.bind(this)
    document.addEventListener("mouseup", this._handler)
  }

  disconnect() {
    document.removeEventListener("mouseup", this._handler)
  }

  // ── Filter / search actions ─────────────────────────────────
  setFilter(event) {
    const f = event?.params?.filter || event?.currentTarget?.dataset?.narrativeLinkFilterParam
    if (!f) return
    this.filterValue = f
    this._paintFilterButtons()
    this._applyVisibility()
  }

  search() {
    this._applyVisibility()
  }

  clearSearch() {
    if (this.hasSearchTarget) this.searchTarget.value = ""
    this._applyVisibility()
  }

  // ── Selection-driven jump ───────────────────────────────────
  _onMouseUp() {
    setTimeout(() => this._process(), 0)
  }

  _process() {
    if (!this.hasTranscriptTarget) return
    const sel = window.getSelection()
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return

    const range = sel.getRangeAt(0)
    const inSource = this.sourceTargets.some(el =>
      el.contains(range.startContainer) && el.contains(range.endContainer)
    )
    if (!inSource) return

    const text = sel.toString().trim()
    if (text.length < 3) return

    this._jumpTo(text)
  }

  _jumpTo(query) {
    const span = this._findSpan(this._originalText, query)
    if (!span) {
      this._render()
      this._applyVisibility()
      this._setStatus(`No match for "${this._truncate(query, 40)}"`, "miss")
      return
    }
    this._render(span.start, span.end)
    this._applyVisibility()
    this._setStatus("Jumped to matching spot in transcript", "hit")
    this._scroll()
  }

  _findSpan(text, query) {
    const lower = text.toLowerCase()
    const qLower = query.toLowerCase().replace(/\s+/g, " ").trim()
    let idx = lower.indexOf(qLower)
    if (idx >= 0) return { start: idx, end: idx + qLower.length }

    const qClean = qLower
      .replace(/\[[^\]]*\]/g, " ")
      .replace(PUNCT_RE, " ")
      .replace(/\s+/g, " ")
      .trim()

    const allWords = qClean.split(/\s+/).filter(w => w.length > 0)
    const sigWords = allWords.filter(w => w.length > 2 && !STOP.has(w))
    if (sigWords.length === 0) return null

    const sep = "(?:\\s|\\[[^\\]]*\\]|" + PUNCT_RE.source.slice(1, -2) + ")+"
    for (let n = Math.min(8, sigWords.length); n >= 2; n--) {
      for (let s = 0; s + n <= sigWords.length; s++) {
        const probe = sigWords.slice(s, s + n).map(escapeRe).join(sep)
        const re = new RegExp(probe, "i")
        const m = text.match(re)
        if (m && m.index >= 0) return { start: m.index, end: m.index + m[0].length }
      }
    }

    const sorted = [...sigWords].sort((a, b) => b.length - a.length)
    for (const w of sorted) {
      const re = new RegExp(`\\b${escapeRe(w)}\\b`, "i")
      const m = text.match(re)
      if (m && m.index >= 0) return { start: m.index, end: m.index + m[0].length }
    }
    return null
  }

  // ── Turn parser ─────────────────────────────────────────────
  _parseTurns(text) {
    const turns = []
    SPEAKER_RE_GLOBAL.lastIndex = 0
    const matches = []
    let m
    while ((m = SPEAKER_RE_GLOBAL.exec(text)) !== null) {
      matches.push({ tagStart: m.index, tagEnd: m.index + m[0].length, name: m[1].trim() })
    }
    if (matches.length === 0) {
      const trimmed = text.trim()
      if (trimmed.length > 0) {
        turns.push({ name: null, role: "other", bodyStart: 0, bodyEnd: text.length })
      }
      return turns
    }
    if (matches[0].tagStart > 0) {
      const lead = text.slice(0, matches[0].tagStart).trim()
      if (lead.length > 0) {
        turns.push({ name: null, role: "other", bodyStart: 0, bodyEnd: matches[0].tagStart })
      }
    }
    for (let i = 0; i < matches.length; i++) {
      const cur  = matches[i]
      const next = matches[i + 1]
      const bodyEnd = next ? next.tagStart : text.length
      turns.push({
        name: cur.name,
        role: this._roleForSpeaker(cur.name),
        bodyStart: cur.tagEnd,
        bodyEnd
      })
    }
    return turns
  }

  _roleForSpeaker(name) {
    const normalized = String(name || "").toLowerCase().trim()
    if (!normalized) return "other"
    if (CLINICIAN_NAMES.has(normalized)) return "clinician"
    if (PATIENT_NAMES.has(normalized)) return "patient"
    if (/^(rn|md|don|lpn|lvn|np|pa)\b/.test(normalized)) return "clinician"
    if (/\b(rn|md|don|lpn|lvn|np|pa|nurse|clinician|doctor|physician)\b/.test(normalized)) return "clinician"
    return "patient"
  }

  // Server-provided speaker directory: [{ match:[…], name, title, color, initials, photoUrl }]
  _parseRoster() {
    try {
      const raw = this.transcriptTarget.dataset.roster
      const parsed = raw ? JSON.parse(raw) : []
      return Array.isArray(parsed) ? parsed : []
    } catch (_e) {
      return []
    }
  }

  // Per-turn audio timing from Deepgram: [{ speaker, start, end }], in the same
  // order as the [Speaker:] turns. Empty when the recording had no diarized
  // timing (Web Speech, imported/seeded, or pre-feature visits).
  _parseSegments() {
    try {
      const raw = this.transcriptTarget.dataset.segments
      const parsed = raw ? JSON.parse(raw) : []
      return Array.isArray(parsed) ? parsed.filter(s => s && typeof s.start === "number") : []
    } catch (_e) {
      return []
    }
  }

  // Seek the bedside audio to a turn's start and play until its end. Finds the
  // shared <audio> by its data marker so the transcript stays decoupled from
  // the player partial.
  _playSegment(start, end) {
    const audio = document.querySelector("[data-visit-audio]")
    if (!audio) return
    if (this._segStopper) audio.removeEventListener("timeupdate", this._segStopper)
    try { audio.currentTime = start } catch (_e) { /* not yet seekable */ }
    if (typeof end === "number") {
      this._segStopper = () => {
        if (audio.currentTime >= end) {
          audio.pause()
          audio.removeEventListener("timeupdate", this._segStopper)
          this._segStopper = null
        }
      }
      audio.addEventListener("timeupdate", this._segStopper)
    }
    audio.play().catch(() => {})
  }

  _fmtTime(s) {
    const m = Math.floor(s / 60)
    const sec = Math.floor(s % 60)
    return `${m}:${String(sec).padStart(2, "0")}`
  }

  // Resolve a [Speaker:] tag to a roster entry (name/title/photo/color).
  _identityFor(name) {
    const normalized = String(name || "").toLowerCase().trim()
    if (!normalized || !this._roster) return null
    return this._roster.find(e => Array.isArray(e.match) && e.match.includes(normalized)) || null
  }

  _initialsFrom(name) {
    const parts = String(name || "").trim().split(/\s+/).filter(Boolean).map(w => w[0])
    return parts.length ? parts.slice(0, 2).join("").toUpperCase() : "··"
  }

  // ── Render turn-blocks ──────────────────────────────────────
  _render(markStart, markEnd) {
    if (!this.hasTranscriptTarget) return
    const pre = this.transcriptTarget
    pre.innerHTML = ""

    const fallbackByName = {}
    let paletteIdx = 0
    const colorFor = (name, role) => {
      if (role !== "other" && ROLE_TINTS[role]) return ROLE_TINTS[role].border
      const key = (name || "other").toLowerCase()
      if (fallbackByName[key]) return fallbackByName[key]
      const c = FALLBACK_PALETTE[paletteIdx % FALLBACK_PALETTE.length]
      paletteIdx++
      fallbackByName[key] = c
      return c
    }

    let segIdx = 0
    for (const turn of this._turns) {
      // Segments align with named [Speaker:] turns in order; a leading
      // untagged block (rare) has no timing and doesn't advance the index.
      const seg = turn.name ? this._segments[segIdx] : null
      if (turn.name) segIdx++
      const tint     = ROLE_TINTS[turn.role] || ROLE_TINTS.other
      const identity = this._identityFor(turn.name)
      const color    = (identity && identity.color) || colorFor(turn.name, turn.role)

      const container = document.createElement("div")
      container.dataset.role = turn.role
      container.dataset.speaker = (turn.name || "").toLowerCase()
      container.className = "rounded-lg px-3 py-2 mb-2 border-l-[3px] transition-opacity"
      container.style.backgroundColor = tint.bg
      container.style.borderLeftColor = color

      if (turn.name || identity) {
        const header = document.createElement("div")
        header.className = "flex items-center gap-2 mb-1"

        // Avatar: real photo if we have one, else a colored initials chip.
        const photoUrl = identity && identity.photoUrl
        const initials = (identity && identity.initials) || this._initialsFrom(turn.name)
        if (photoUrl) {
          const img = document.createElement("img")
          img.src = photoUrl
          img.alt = (identity && identity.name) || turn.name || ""
          img.className = "w-6 h-6 rounded-full object-cover flex-shrink-0 border border-[#EFECE6]"
          header.appendChild(img)
        } else {
          const chip = document.createElement("div")
          chip.textContent = initials
          chip.className = "w-6 h-6 rounded-full flex-shrink-0 inline-flex items-center justify-center text-white"
          chip.style.backgroundColor = color
          chip.style.fontSize = "9px"
          chip.style.fontWeight = "700"
          chip.style.fontStyle = "normal"
          header.appendChild(chip)
        }

        const nameEl = document.createElement("span")
        nameEl.textContent = (identity && identity.name) || turn.name
        nameEl.style.color = color
        nameEl.style.fontWeight = "700"
        nameEl.style.fontSize = "11px"
        nameEl.style.fontStyle = "normal"
        header.appendChild(nameEl)

        const title = identity && identity.title
        if (title) {
          const titleEl = document.createElement("span")
          titleEl.textContent = title
          titleEl.className = "text-[8px] uppercase tracking-widest text-[#6B665F] bg-white border border-[#EFECE6] rounded-full px-1.5 py-0.5"
          titleEl.style.fontStyle = "normal"
          header.appendChild(titleEl)
        }

        // Per-turn audio: a ▶ that seeks the bedside recording to this turn.
        if (seg && typeof seg.start === "number") {
          container.dataset.start = String(seg.start)
          if (typeof seg.end === "number") container.dataset.end = String(seg.end)
          const play = document.createElement("button")
          play.type = "button"
          play.title = `Play from ${this._fmtTime(seg.start)}`
          play.setAttribute("aria-label", "Play this turn from the recording")
          play.className = "ml-auto flex-shrink-0 w-6 h-6 rounded-full inline-flex items-center justify-center text-[#6B665F] border border-[#D9D5CD] hover:text-white hover:bg-[#1D1C1A] transition no-print"
          play.innerHTML = '<i class="ri-play-fill" style="font-size:12px"></i>'
          play.addEventListener("click", (e) => {
            e.preventDefault()
            e.stopPropagation()
            this._playSegment(seg.start, typeof seg.end === "number" ? seg.end : null)
          })
          header.appendChild(play)
        }

        container.appendChild(header)
      }

      const body = document.createElement("div")
      body.className = "whitespace-pre-wrap font-serif italic text-[12px] text-[#3A3936] leading-relaxed"
      this._renderBody(turn.bodyStart, turn.bodyEnd, markStart, markEnd, body)

      // Cache for fast filter/search; pull plain text once.
      const plain = this._originalText.slice(turn.bodyStart, turn.bodyEnd).toLowerCase()
      const hasMedical = MEDICAL_RE.test(plain)
      MEDICAL_RE.lastIndex = 0
      container.dataset.text = plain
      container.dataset.hasKeyword = hasMedical ? "true" : "false"

      container.appendChild(body)
      pre.appendChild(container)
    }
  }

  _renderBody(segStart, segEnd, markStart, markEnd, parent) {
    const text = this._originalText.slice(segStart, segEnd)
    const segLen = text.length
    const lMs = markStart != null ? Math.max(0, markStart - segStart) : null
    const lMe = markEnd   != null ? Math.min(segLen, markEnd   - segStart) : null
    const hasMark = lMs != null && lMe != null && lMe > lMs

    const bolds = []
    MEDICAL_RE.lastIndex = 0
    let m
    while ((m = MEDICAL_RE.exec(text)) !== null) {
      if (m[0].length === 0) { MEDICAL_RE.lastIndex++; continue }
      bolds.push({ start: m.index, end: m.index + m[0].length })
    }

    if (bolds.length === 0 && !hasMark) {
      parent.appendChild(document.createTextNode(text))
      return
    }

    const cuts = new Set([0, segLen])
    for (const r of bolds) { cuts.add(r.start); cuts.add(r.end) }
    if (hasMark) { cuts.add(lMs); cuts.add(lMe) }
    const sorted = [...cuts].sort((a, b) => a - b)

    let markWrapper = null
    for (let i = 0; i < sorted.length - 1; i++) {
      const a = sorted[i], b = sorted[i + 1]
      if (a >= b) continue
      const piece = text.slice(a, b)
      const isBold   = bolds.some(r => r.start <= a && r.end >= b)
      const isMarked = hasMark && a >= lMs && b <= lMe

      let node = document.createTextNode(piece)
      if (isBold) {
        const strong = document.createElement("strong")
        strong.style.fontWeight = "700"
        strong.style.fontStyle = "normal"
        strong.style.color = "#1D1C1A"
        strong.appendChild(node)
        node = strong
      }
      if (isMarked) {
        if (!markWrapper) {
          markWrapper = document.createElement("mark")
          markWrapper.dataset.narrativeLinkMark = "true"
          markWrapper.className = "bg-[#FFF3A1] text-[#1D1C1A] rounded px-0.5 ring-2 ring-[#D97757]"
          parent.appendChild(markWrapper)
        }
        markWrapper.appendChild(node)
      } else {
        markWrapper = null
        parent.appendChild(node)
      }
    }
  }

  // ── Filter / search visibility ──────────────────────────────
  _applyVisibility() {
    if (!this.hasTranscriptTarget) return
    const filter = this.filterValue
    const q = (this.hasSearchTarget ? this.searchTarget.value : "").trim().toLowerCase()

    let visible = 0
    let total   = 0
    this.transcriptTarget.querySelectorAll("[data-role]").forEach(el => {
      total++
      const role = el.dataset.role
      const hasKw = el.dataset.hasKeyword === "true"
      const text = el.dataset.text || ""

      let ok = true
      if (filter === "patient")        ok = role === "patient"
      else if (filter === "clinician") ok = role === "clinician"
      else if (filter === "keywords")  ok = hasKw

      if (ok && q.length > 0) ok = text.includes(q)

      el.style.display = ok ? "" : "none"
      if (ok) visible++
    })

    if (this.hasCountTarget) {
      const showsAll = filter === "all" && q.length === 0
      this.countTarget.textContent = showsAll
        ? `${total} turn${total === 1 ? "" : "s"}`
        : `${visible} of ${total} turn${total === 1 ? "" : "s"}`
    }
  }

  _paintFilterButtons() {
    if (!this.hasFilterTarget) return
    this.filterTargets.forEach(b => {
      const isActive = b.dataset.narrativeLinkFilterParam === this.filterValue
      b.classList.toggle("bg-white", isActive)
      b.classList.toggle("text-[#1D1C1A]", isActive)
      b.classList.toggle("shadow-sm", isActive)
      b.classList.toggle("text-[#6B665F]", !isActive)
    })
  }

  _scroll() {
    const mark = this.transcriptTarget.querySelector("[data-narrative-link-mark]")
    if (!mark) return
    requestAnimationFrame(() => {
      mark.scrollIntoView({ behavior: "smooth", block: "center", inline: "nearest" })
    })
  }

  _setStatus(msg, kind) {
    if (!this.hasStatusTarget) return
    const el = this.statusTarget
    el.textContent = msg
    el.classList.remove("text-[#2F6F4E]", "text-[#C1403A]", "text-[#6B665F]")
    el.classList.add(kind === "hit" ? "text-[#2F6F4E]" : kind === "miss" ? "text-[#C1403A]" : "text-[#6B665F]")
  }

  _truncate(s, n) {
    return s.length > n ? s.slice(0, n - 1) + "…" : s
  }
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}
