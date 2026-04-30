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
  static values  = { url: String, agenciesUrl: String, callbackUrl: String }

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
    const lookupTried = !!data?.query
    const where = data?.query?.zip || data?.query?.city || data?.query?.name ||
                  (data?.query?.state === "FL" ? "Florida" : data?.query?.state)

    if (data?.error) {
      this._renderAssistant(data.error, "error")
    } else if (data?.answer) {
      this._renderAssistant(data.answer)
    } else if (!cardsReady) {
      this._renderAssistant("We couldn't reach the assistant right now. Tap 'Request a callback' below.", "error")
    }

    if (cardsReady) {
      this._renderAgencyCards(data.agencies)
    } else if (lookupTried) {
      const noun = data.query.name ? `partner named "${data.query.name}"` : "partner"
      this._renderAssistant(`I couldn't find a HosAlivio ${noun} around or near ${where}. We're adding new partners every week. Tap "Request a callback" below and our team will personally help you find a vetted hospice that serves you.`)
    }

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
