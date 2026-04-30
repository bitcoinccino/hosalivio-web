import { Controller } from "@hotwired/stimulus"

// When the RN highlights a word / phrase / paragraph in the polished
// note, find the closest matching span in the right-sidebar
// transcript, scroll it into view, and wrap it in <mark>. Also
// renders speaker tags ([Pascal:], [Maria:], …) as colored, bracket-
// less labels so the transcript reads more like a script.
//
// Targets:
//   source      — note panes the RN selects from (Medicaid / Team)
//   transcript  — the <pre> holding the raw transcript
//   status      — small caption updated on hit/miss (optional)
const STOP = new Set([
  "the","and","for","with","that","this","from","into","over","about",
  "then","than","they","them","but","not","are","was","has","have","had",
  "you","she","her","his","him","its","our","your","is","of","to","a",
  "an","in","on","at","by","as","be","or","it","we","i"
])

const PUNCT_RE = /[.,!?;:'"\(\)\[\]\-—]/g
const SPEAKER_RE_GLOBAL = /\[([^\]]+):\]/g

// Medical / hospice vocabulary that should pop visually in the
// transcript so the RN can scan to clinical content fast. Multi-
// word phrases come first so they win over single-word fragments
// (e.g. "shortness of breath" before "breath"). Matched case-
// insensitively with word boundaries.
const MEDICAL_TERMS = [
  // hospice / palliative
  "comfort-focused", "comfort care", "code status", "advance directive",
  "hospice", "palliative", "DNR", "DNI", "POLST", "MOLST",
  "prognosis", "terminal", "eligibility", "eligible", "certification", "recertification",
  // symptoms
  "shortness of breath", "weight loss", "pressure injury",
  "pain", "dyspnea", "edema", "nausea", "vomiting", "fatigue", "hemoptysis",
  "delirium", "confusion", "agitation", "anxiety", "depression",
  "constipation", "diarrhea", "incontinence", "anorexia", "cachexia", "ascites",
  "fever", "cough", "wheezing", "bleeding", "weakness", "tremor", "seizure",
  "headache", "dizziness", "wound", "ulcer", "fall", "falls",
  // conditions
  "metastatic", "myocardial infarction", "atrial fibrillation",
  "heart failure", "kidney disease", "renal failure", "liver disease",
  "cancer", "tumor", "metastasis", "malignancy", "carcinoma", "leukemia", "lymphoma",
  "COPD", "emphysema", "bronchitis", "asthma", "pneumonia",
  "CHF", "MI", "arrhythmia",
  "stroke", "CVA", "TIA", "dementia", "Alzheimer", "Parkinson", "ALS",
  "diabetes", "diabetic", "hypertension", "hyperlipidemia",
  "ESRD", "dialysis", "cirrhosis", "hepatitis",
  // vitals
  "blood pressure", "heart rate", "respiratory rate",
  "BP", "pulse", "temperature", "oxygen", "SpO2", "O2", "saturation",
  // medications
  "MS Contin", "Ativan", "Haldol", "Versed", "Zofran", "Reglan", "Coumadin", "Tylenol",
  "morphine", "oxycodone", "hydromorphone", "fentanyl", "methadone",
  "lorazepam", "haloperidol", "midazolam",
  "dexamethasone", "prednisone",
  "ondansetron", "metoclopramide", "scopolamine", "atropine",
  "ibuprofen", "acetaminophen", "aspirin",
  "insulin", "metformin", "warfarin", "heparin",
  // equipment
  "oxygen concentrator", "nasal cannula", "hospital bed", "bedside commode",
  "Foley catheter", "PEG tube", "G-tube", "feeding tube",
  "walker", "wheelchair", "commode",
  // ADLs
  "bathing", "dressing", "toileting", "transferring", "feeding", "continence", "ambulation",
  // roles
  "registered nurse", "social worker", "RN", "MD", "physician", "chaplain", "aide", "CNA",
  "caregiver", "IDT", "interdisciplinary",
  // labs / measures
  "albumin", "creatinine", "GFR", "A1C", "PPS", "FAST", "Karnofsky"
]

const MEDICAL_RE = new RegExp(
  "\\b(?:" +
    MEDICAL_TERMS
      .sort((a, b) => b.length - a.length) // longer phrases first
      .map(t => t.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\s+/g, "\\s+"))
      .join("|") +
  ")\\b",
  "gi"
)

// Stable color palette for speakers we know by name. Anyone we
// don't recognize cycles through `palette` based on first-seen
// order so two speakers never collide.
const NAMED_COLORS = {
  pascal: "#D97757",   // terracotta — clinician
  maria:  "#2F6F4E",   // sage      — patient
  rn:     "#D97757",
  patient:"#2F6F4E"
}
const FALLBACK_PALETTE = ["#2B4A7A", "#7E3FAD", "#A8423E", "#1D1C1A", "#5C7A3E"]

export default class extends Controller {
  static targets = ["source", "transcript", "status"]

  connect() {
    if (this.hasTranscriptTarget) {
      this._originalText = this.transcriptTarget.textContent
      this._render()
    }
    this._handler = this._onMouseUp.bind(this)
    document.addEventListener("mouseup", this._handler)
  }

  disconnect() {
    document.removeEventListener("mouseup", this._handler)
  }

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
    const transcript = this._originalText || ""
    const span = this._findSpan(transcript, query)
    if (!span) {
      this._render()
      this._setStatus(`No match for "${this._truncate(query, 40)}"`, "miss")
      return
    }
    this._render(span.start, span.end)
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

  // Render the whole transcript: speaker tags become colored
  // bracket-less labels; a match range (if given) gets wrapped
  // in <mark>. Indices refer to positions in `_originalText`,
  // i.e. the raw bracketed transcript.
  _render(markStart, markEnd) {
    const text = this._originalText || ""
    const pre  = this.transcriptTarget
    if (!pre) return

    // Tokenize into speaker-tag segments and text segments.
    const segments = []
    let cursor = 0
    SPEAKER_RE_GLOBAL.lastIndex = 0
    let m
    while ((m = SPEAKER_RE_GLOBAL.exec(text)) !== null) {
      if (m.index > cursor) {
        segments.push({ type: "text", start: cursor, end: m.index })
      }
      segments.push({ type: "speaker", start: m.index, end: m.index + m[0].length, name: m[1] })
      cursor = m.index + m[0].length
    }
    if (cursor < text.length) {
      segments.push({ type: "text", start: cursor, end: text.length })
    }

    // Stable per-name color (first-seen order for unknowns).
    const colorByName = {}
    let paletteIdx = 0
    const colorFor = (name) => {
      const key = name.trim().toLowerCase()
      if (NAMED_COLORS[key]) return NAMED_COLORS[key]
      if (colorByName[key]) return colorByName[key]
      const c = FALLBACK_PALETTE[paletteIdx % FALLBACK_PALETTE.length]
      paletteIdx++
      colorByName[key] = c
      return c
    }

    pre.innerHTML = ""

    for (const seg of segments) {
      if (seg.type === "speaker") {
        const label = document.createElement("span")
        label.textContent = seg.name + ":"
        label.style.color = colorFor(seg.name)
        label.style.fontWeight = "700"
        label.style.fontStyle = "normal"
        label.style.marginRight = "4px"
        pre.appendChild(label)
        continue
      }
      this._renderTextSegment(seg.start, seg.end, markStart, markEnd, pre)
    }
  }

  // Walks one text segment, finds medical terms (bold) and any
  // overlapping mark range, then emits DOM nodes that compose
  // bold + mark cleanly.
  _renderTextSegment(segStart, segEnd, markStart, markEnd, parent) {
    const text = this._originalText.slice(segStart, segEnd)
    const segLen = text.length
    const lMs = markStart != null ? Math.max(0, markStart - segStart) : null
    const lMe = markEnd   != null ? Math.min(segLen, markEnd   - segStart) : null
    const hasMark = lMs != null && lMe != null && lMe > lMs

    // Find bold ranges (medical terms) in segment-local coords
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

    // Cut points where styling changes
    const cuts = new Set([0, segLen])
    for (const r of bolds) { cuts.add(r.start); cuts.add(r.end) }
    if (hasMark) { cuts.add(lMs); cuts.add(lMe) }
    const sorted = [...cuts].sort((a, b) => a - b)

    // Emit pieces, coalescing contiguous marked pieces under one <mark>
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
