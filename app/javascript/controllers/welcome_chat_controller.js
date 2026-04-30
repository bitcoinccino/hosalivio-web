import { Controller } from "@hotwired/stimulus"

// Hero "Ask HosAlivio" composer on the public welcome page. Single
// entry point for both Q&A (POST /public_chat) and partner-agency
// lookup (GET /public_chat/agencies). Mirrors the patient-dashboard
// chat pattern: rounded pill at the bottom, message bubbles in a
// transcript above. Detects a 5-digit ZIP in the question and fires
// the agency lookup in parallel; otherwise asks the bot first and
// uses any city / ZIP it sees in the conversation later.
//
// Targets:
//   transcript  — message log container (assistant + user bubbles + cards)
//   form        — submit handler
//   input       — text input
//   send        — submit button (disabled while in flight)
//   intro       — the static intro line (hidden after first turn)
//   audience    — hidden field carrying "family" or "partner"
//   audienceBtn — the two intent chips above the composer
//   quickStart  — wrapper around the "Three-Tap" relief chips
//                 (cost / home / how to start). Hidden after first turn.
export default class extends Controller {
  static targets = ["transcript", "form", "input", "send", "intro", "audience", "audienceBtn", "quickStart"]
  static values  = { url: String, agenciesUrl: String, callbackUrl: String, feedbackUrl: String }

  connect() {
    this._sending = false
  }

  // Quick-start chip click — fills the input and immediately
  // submits, so the visitor goes from "blank page anxiety" to
  // a real conversation in one tap.
  quickStart(event) {
    const q = event?.params?.question || event?.currentTarget?.dataset?.welcomeChatQuestionParam
    if (!q || !this.hasInputTarget) return
    this.inputTarget.value = q
    this.ask(event)
  }

  setAudience(event) {
    const a = event?.currentTarget?.dataset?.welcomeChatAudienceParam
    if (!a) return
    if (this.hasAudienceTarget) this.audienceTarget.value = a
    this.audienceBtnTargets.forEach(b => {
      const active = b.dataset.welcomeChatAudienceParam === a
      b.classList.toggle("bg-white",       active)
      b.classList.toggle("text-[#1D1C1A]", active)
      b.classList.toggle("shadow-sm",      active)
      b.classList.toggle("text-[#6B665F]", !active)
    })
  }

  async ask(event) {
    event?.preventDefault?.()
    if (this._sending) return
    const q = this.inputTarget.value.trim()
    if (q.length === 0) return

    this._sending = true
    this.sendTarget.disabled = true
    if (this.hasIntroTarget)      this.introTarget.classList.add("hidden")
    if (this.hasQuickStartTarget) this.quickStartTarget.classList.add("hidden")

    this._renderUser(q)
    this.inputTarget.value = ""
    const thinking = this._renderThinking()

    const audience = this._currentAudience()

    // Single round-trip to /public_chat — the backend now does
    // its own ZIP/city/agency-name detection, runs the partner
    // lookup, AND tailors the brain's reply with that context, so
    // the bot acknowledges the cards rather than asking "what do
    // you mean?" The response payload is { answer, query, agencies }.
    const data = await this._fetchAnswer(q, audience).catch(err => ({ error: err.message || "Network error" }))
    thinking.remove()

    const cardsReady = !!data?.agencies?.length
    const noResults  = data?.no_results === true
    const where = data?.query?.zip || data?.query?.city || data?.query?.name ||
                  (data?.query?.state === "FL" ? "Florida" : data?.query?.state)

    if (data?.error) {
      this._renderAssistant(data.error, "error")
    } else if (noResults) {
      this._renderNoResultsCard(data.query, where)
    } else if (data?.answer) {
      const wrap = this._renderAssistant(data.answer)
      this._attachFeedback(wrap, q, data.answer, audience)
    } else if (!cardsReady) {
      this._renderAssistant("We couldn't reach the assistant right now. Tap 'Talk to a hospice nurse · 24/7' below.", "error")
    }

    if (cardsReady) this._renderAgencyCards(data.agencies)

    this._sending = false
    this.sendTarget.disabled = false
    this.inputTarget.focus()
  }

  // ── network ────────────────────────────────────────────────
  async _fetchAnswer(question, audience) {
    const resp = await fetch(this.urlValue, {
      method: "POST",
      headers: { "Content-Type": "application/json", "Accept": "application/json" },
      body: JSON.stringify({ question, audience })
    })
    const data = await resp.json().catch(() => ({}))
    if (!resp.ok) throw new Error(data.error || `HTTP ${resp.status}`)
    return data
  }

  // ── render helpers ─────────────────────────────────────────
  _renderUser(text) {
    const wrap = document.createElement("div")
    wrap.className = "flex justify-end"
    const bubble = document.createElement("div")
    bubble.className = "max-w-[85%] rounded-2xl rounded-br-sm bg-[#D97757] text-white text-[14px] leading-relaxed px-4 py-2.5 shadow-sm"
    bubble.textContent = text
    wrap.appendChild(bubble)
    this.transcriptTarget.appendChild(wrap)
    this._scrollBottom()
  }

  _renderAssistant(text, kind) {
    const wrap = document.createElement("div")
    wrap.className = "flex items-start gap-2"
    wrap.innerHTML = `<div class="w-8 h-8 rounded-full bg-[#D97757] text-white flex items-center justify-center flex-shrink-0"><i class="ri-heart-pulse-line text-sm"></i></div>`
    const bubble = document.createElement("div")
    bubble.className = "max-w-[85%] rounded-2xl rounded-bl-sm border text-[14px] leading-relaxed px-4 py-2.5 whitespace-pre-wrap shadow-sm"
    if (kind === "error") {
      bubble.classList.add("bg-[#FFF3EC]", "border-[#D97757]", "text-[#C1403A]")
    } else {
      bubble.classList.add("bg-[#FBF9F5]", "border-[#EFECE6]", "text-[#1D1C1A]")
    }
    bubble.textContent = text
    wrap.appendChild(bubble)
    this.transcriptTarget.appendChild(wrap)
    this._scrollBottom()
    return wrap
  }

  // Thinking bubble — animated dots inside a HosAlivio-styled
  // assistant bubble. Returned so the caller can .remove() it
  // when the real answer arrives.
  _renderThinking() {
    const wrap = document.createElement("div")
    wrap.className = "flex items-start gap-2"
    wrap.innerHTML = `
      <div class="w-8 h-8 rounded-full bg-[#D97757] text-white flex items-center justify-center flex-shrink-0">
        <i class="ri-heart-pulse-line text-sm"></i>
      </div>
      <div class="rounded-2xl rounded-bl-sm border bg-[#FBF9F5] border-[#EFECE6] text-[#6B665F] text-[13px] italic px-4 py-3 shadow-sm inline-flex items-center gap-2">
        <span>HosAlivio is thinking</span>
        <span class="inline-flex items-end gap-[2px] h-3">
          <span class="w-[5px] h-[5px] rounded-full bg-[#D97757] animate-bounce" style="animation-delay:0s"></span>
          <span class="w-[5px] h-[5px] rounded-full bg-[#D97757] animate-bounce" style="animation-delay:0.15s"></span>
          <span class="w-[5px] h-[5px] rounded-full bg-[#D97757] animate-bounce" style="animation-delay:0.3s"></span>
        </span>
      </div>
    `
    this.transcriptTarget.appendChild(wrap)
    this._scrollBottom()
    return wrap
  }

  // ── Feedback widget ────────────────────────────────────────
  // Hover-revealed "Did this help?" with thumbs up/down at the
  // bottom of an answer bubble. Soft language, low-opacity icons,
  // hospice-appropriate. Thumbs-down expands an inline comment
  // field + the 24/7 nurse CTA so the visitor isn't left in a
  // dead end. POSTs to /public_chat/feedback on click.
  _attachFeedback(wrap, question, answer, audience) {
    if (!this.hasFeedbackUrlValue) return
    const bubble = wrap.querySelector("div:last-child")
    if (!bubble) return

    const fb = document.createElement("div")
    fb.className = "mt-3 pt-2 border-t border-[#EFECE6] flex items-center justify-end gap-2 text-[11px] text-[#6B665F]"
    fb.innerHTML = `
      <span class="italic">Did this help?</span>
      <button type="button" data-rating="helpful" aria-label="Yes, this helped"
              class="w-8 h-8 rounded-full bg-[#FBF9F5] border border-[#EFECE6] hover:bg-[#E6F0EE] hover:border-[#2F6F4E] hover:text-[#2F6F4E] flex items-center justify-center transition">
        <i class="ri-thumb-up-line text-[14px]"></i>
      </button>
      <button type="button" data-rating="not_helpful" aria-label="No, this missed the mark"
              class="w-8 h-8 rounded-full bg-[#FBF9F5] border border-[#EFECE6] hover:bg-[#FFF3EC] hover:border-[#D97757] hover:text-[#C1403A] flex items-center justify-center transition">
        <i class="ri-thumb-down-line text-[14px]"></i>
      </button>
    `
    bubble.appendChild(fb)

    fb.querySelectorAll("button[data-rating]").forEach(btn => {
      btn.addEventListener("click", () => this._submitFeedback(fb, bubble, btn.dataset.rating, question, answer, audience))
    })
  }

  async _submitFeedback(fbBar, bubble, rating, question, answer, audience, comment = null) {
    try {
      await fetch(this.feedbackUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body:    JSON.stringify({ rating, question, answer, audience, comment })
      })
    } catch (_) { /* best-effort, silent */ }

    if (rating === "helpful") {
      fbBar.innerHTML = `<span class="text-[#2F6F4E] inline-flex items-center gap-1"><i class="ri-heart-fill"></i> Thank you, glad we could help.</span>`
      fbBar.classList.remove("opacity-30")
      fbBar.classList.add("opacity-100")
      return
    }

    // Thumbs down — expand into comment + nurse CTA so the
    // visitor isn't left at a dead end after rating.
    if (comment != null) {
      // Comment already submitted — collapse to thanks
      fbBar.innerHTML = `<span class="text-[#2F6F4E] inline-flex items-center gap-1"><i class="ri-heart-fill"></i> Thanks, we'll improve.</span>`
      fbBar.classList.remove("opacity-30")
      fbBar.classList.add("opacity-100")
      return
    }

    const followUp = document.createElement("div")
    followUp.className = "mt-3 pt-3 border-t border-[#EFECE6] space-y-2"
    followUp.innerHTML = `
      <div class="text-[11px] text-[#6B665F] italic">We're sorry. What did we miss? <span class="not-italic">(optional)</span></div>
      <textarea rows="2" maxlength="500" placeholder="A line or two helps us improve…"
                class="w-full px-3 py-2 rounded-lg border border-[#D9D5CD] bg-[#FBF9F5] focus:bg-white focus:border-[#D97757] focus:outline-none text-[12px] resize-none"></textarea>
      <div class="flex items-center justify-between gap-2 flex-wrap">
        <a href="${escapeHtml(this.callbackUrlValue || '#')}" class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-[#2F6F4E] hover:bg-[#265a3d] text-white text-[11px] font-bold uppercase tracking-widest">
          <i class="ri-phone-fill"></i> Talk to a nurse · 24/7
        </a>
        <button type="button" class="text-[11px] text-[#D97757] hover:text-[#c46a4b] font-bold uppercase tracking-widest">
          Send feedback
        </button>
      </div>
    `
    bubble.appendChild(followUp)
    fbBar.remove()
    const ta = followUp.querySelector("textarea")
    const send = followUp.querySelector("button")
    ta.focus()
    send.addEventListener("click", () => {
      const text = ta.value.trim()
      followUp.remove()
      const collapsed = document.createElement("div")
      collapsed.className = "mt-2 pt-2 border-t border-[#EFECE6] text-[11px] text-[#2F6F4E] italic"
      collapsed.innerHTML = `<i class="ri-heart-fill"></i> Thanks, we'll improve.`
      bubble.appendChild(collapsed)
      // Best-effort second POST with the comment
      fetch(this.feedbackUrlValue, {
        method:  "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body:    JSON.stringify({ rating: "not_helpful", question, answer, audience, comment: text })
      }).catch(() => {})
    })
  }

  // Structured "still growing" card. Renders alongside the
  // assistant avatar so it reads as part of the conversation,
  // but the CTA lives on the card itself (single source of
  // truth: no extra chatty bubble repeating the action).
  _renderNoResultsCard(query, where) {
    const headline = query?.zip
      ? `We're still growing in ${where}.`
      : query?.name
        ? `We don't have a partner named "${query.name}" yet.`
        : query?.state
          ? `Our partner network is still expanding in ${where}.`
          : `We don't have a partner near ${where} yet.`

    const subline = query?.zip
      ? `We don't have a direct partner in ${where} yet, but we can still help you find a vetted hospice today.`
      : `New partners are added every week, and our team can match you with a vetted hospice today.`

    const cta = this.callbackUrlValue || "#"

    const wrap = document.createElement("div")
    wrap.className = "flex items-start gap-2"
    wrap.innerHTML = `
      <div class="w-8 h-8 rounded-full bg-[#D97757] text-white flex items-center justify-center flex-shrink-0">
        <i class="ri-heart-pulse-line text-sm"></i>
      </div>
      <div class="max-w-[85%] rounded-2xl rounded-bl-sm border border-[#EFECE6] bg-white shadow-sm px-4 py-3">
        <div class="font-serif text-[15px] text-[#1D1C1A] mb-1">${escapeHtml(headline)}</div>
        <p class="text-[13px] text-[#3A3936] leading-relaxed mb-3">${escapeHtml(subline)}</p>
        <a href="${escapeHtml(cta)}" class="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-[#2F6F4E] hover:bg-[#265a3d] text-white text-[12px] font-bold uppercase tracking-widest shadow-sm transition">
          <span class="relative inline-flex w-2 h-2">
            <span class="absolute inline-flex w-full h-full rounded-full bg-white opacity-60 animate-ping"></span>
            <span class="relative inline-flex w-2 h-2 rounded-full bg-white"></span>
          </span>
          <i class="ri-phone-fill"></i>
          Talk to a hospice nurse · 24/7
        </a>
      </div>
    `
    this.transcriptTarget.appendChild(wrap)
    this._scrollBottom()
  }

  _renderAgencyCards(agencies) {
    const container = document.createElement("div")
    container.className = "ml-10 grid gap-2"
    agencies.forEach(a => {
      const card = document.createElement("div")
      card.className = "rounded-2xl border border-[#EFECE6] bg-white p-4 shadow-sm"
      const name = (a.agency_dba && a.agency_dba !== a.agency_name) ? `${a.agency_name} (${a.agency_dba})` : a.agency_name
      const langs = (a.languages || []).map(l => l.toUpperCase()).join(" · ")
      // Pre-fill the inquiry form with which agency the visitor
      // wants — keeps the callback request specific so the
      // partnerships team isn't guessing.
      const callbackUrl = this.callbackUrlValue
        ? `${this.callbackUrlValue}?agency_name=${encodeURIComponent(name || '')}`
        : "#"
      card.innerHTML = `
        <div class="flex items-start justify-between gap-2 flex-wrap">
          <div class="min-w-0">
            <div class="text-[14px] font-bold text-[#1D1C1A] truncate">${escapeHtml(name || "Partner agency")}</div>
            ${a.branch_name ? `<div class="text-[12px] text-[#6B665F] truncate">${escapeHtml(a.branch_name)}</div>` : ""}
          </div>
          ${a.accepting ? `<span class="text-[10px] uppercase tracking-widest font-bold text-[#2F6F4E] bg-[#E6F0EE] border border-[#2F6F4E] rounded-full px-2 py-0.5">Accepting</span>` : ""}
        </div>
        ${a.address ? `<div class="text-[12px] text-[#6B665F] mt-2"><i class="ri-map-pin-line"></i> ${escapeHtml(a.address)}</div>` : ""}
        ${a.phone ? `<div class="text-[12px] text-[#6B665F] mt-0.5"><i class="ri-phone-line"></i> ${escapeHtml(a.phone)}${a.after_hours && a.after_hours !== a.phone ? ` <span class="text-[#D9D5CD]">·</span> after hours ${escapeHtml(a.after_hours)}` : ""}</div>` : ""}
        ${langs ? `<div class="text-[11px] text-[#6B665F] mt-0.5"><i class="ri-translate-2"></i> ${escapeHtml(langs)}</div>` : ""}
        ${a.match_reason ? `<div class="text-[10px] text-[#D97757] mt-1 font-bold uppercase tracking-widest">${escapeHtml(a.match_reason)}</div>` : ""}
        <div class="mt-3">
          <a href="${escapeHtml(callbackUrl)}" class="inline-flex items-center gap-1.5 px-4 py-2 rounded-full bg-[#D97757] hover:bg-[#c46a4b] text-white text-[13px] font-semibold w-full justify-center sm:w-auto">
            <i class="ri-phone-fill"></i> Request call
          </a>
        </div>
      `
      container.appendChild(card)
    })
    this.transcriptTarget.appendChild(container)
    this._scrollBottom()
  }

  _scrollBottom() {
    requestAnimationFrame(() => {
      this.transcriptTarget.scrollTop = this.transcriptTarget.scrollHeight
    })
  }

  _currentAudience() {
    return this.hasAudienceTarget ? this.audienceTarget.value : "family"
  }
}

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}

function stripPhone(s) {
  return String(s ?? "").replace(/[^\d+]/g, "")
}
