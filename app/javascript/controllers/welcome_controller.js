import { Controller } from "@hotwired/stimulus"

// Public landing-page conversation. Stateless: nothing is persisted
// to the clinical backend until the user explicitly submits the capture form.
export default class extends Controller {
  static targets = ["thread", "chips", "capture", "captureDialog", "captureThanks", "anythingInput", "partnerBanner", "partnerBannerName"]
  static values  = { prompts: Object }

  connect() {
    // Track which prompts have already been answered so we don't
    // re-offer them as follow-ups.
    this._seen = new Set()
    // Context for the capture form submission
    this._partnerId      = null
    this._partnerName    = null
    this._question       = null
    this._sourcePrompt   = "capture"
  }

  // Sidebar nav: "For families" jumps to the benefits section AND flips
  // the slide toggle to family so the family panel renders by the time
  // the scroll lands.
  showFamily(event)  { this._jumpToBenefits(event, "family") }
  showPartner(event) { this._jumpToBenefits(event, "partner") }
  showFaq(event) {
    event?.preventDefault()
    document.getElementById("faq")?.scrollIntoView({ behavior: "smooth", block: "start" })
  }

  _jumpToBenefits(event, audience) {
    event?.preventDefault()
    const el = document.getElementById("benefits")
    if (el) el.dataset.audience = audience
    el?.scrollIntoView({ behavior: "smooth", block: "start" })
  }

  // Clicked the "Contact" button on a partner card. Set the partner context
  // so submitCapture knows which agency to route to, then open the modal.
  contactPartner(event) {
    event.preventDefault()
    const { agencyId, agencyName } = event.currentTarget.dataset
    this._partnerId    = agencyId
    this._partnerName  = agencyName
    this._sourcePrompt = "partner_card"

    if (this.hasPartnerBannerTarget) {
      this.partnerBannerNameTarget.textContent = agencyName || "this partner"
      this.partnerBannerTarget.classList.remove("hidden")
    }
    this._openCaptureModal()
  }

  closeCapture(event) {
    if (event) event.preventDefault?.()
    if (!this.hasCaptureTarget) return
    this.captureTarget.classList.add("hidden")
    document.body.style.overflow = ""
    // Reset thanks so next open shows the form
    if (this.hasCaptureThanksTarget) this.captureThanksTarget.classList.add("hidden")
    const form = this.captureTarget.querySelector("form")
    if (form) form.classList.remove("hidden")
  }

  // Click on the backdrop (the modal container itself, not its inner dialog) closes it.
  backdropClose(event) {
    if (event.target === this.captureTarget) this.closeCapture(event)
  }

  _openCaptureModal() {
    if (!this.hasCaptureTarget) return
    // Reset the form/thanks state so each open is clean
    if (this.hasCaptureThanksTarget) this.captureThanksTarget.classList.add("hidden")
    const form = this.captureTarget.querySelector("form")
    if (form) { form.reset(); form.classList.remove("hidden") }
    if (!this._partnerId && this.hasPartnerBannerTarget) {
      this.partnerBannerTarget.classList.add("hidden")
    }
    this.captureTarget.classList.remove("hidden")
    // Prevent page scroll behind the modal
    document.body.style.overflow = "hidden"
    // Focus the first input
    const first = this.captureTarget.querySelector("input")
    if (first) setTimeout(() => first.focus(), 50)
  }

  choosePrompt(event) {
    event.preventDefault()
    const id = event.currentTarget.dataset.promptId
    const prompt = this.promptsValue[id]
    if (!prompt) return

    this._seen.add(id)
    this._appendUserBubble(prompt.label)
    this._appendHosalivioTyping().then(el => {
      // Small delay so it *feels* conversational.
      setTimeout(() => this._swapTypingForAnswer(el, prompt), 450)
    })

    // Hide the starter-chip card once the conversation begins (only once).
    if (this.hasChipsTarget) this.chipsTarget.classList.add("hidden")
  }

  async submitCapture(event) {
    event.preventDefault()
    const form = event.target
    const fd   = new FormData(form)

    const payload = {
      agency_id:     this._partnerId,          // null for "Ask HosAlivio anything" / general
      source_prompt: this._sourcePrompt,
      name:          fd.get("name"),
      contact:       fd.get("contact"),
      zip:           fd.get("zip"),
      question:      this._question || ""
    }

    const csrfMeta = document.querySelector("meta[name='csrf-token']")
    const csrf     = csrfMeta ? csrfMeta.content : ""

    try {
      const resp = await fetch("/inquiries", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": csrf
        },
        body: JSON.stringify(payload)
      })
      if (!resp.ok) {
        const err = await resp.text()
        console.error("Inquiry POST failed:", resp.status, err)
        alert("We couldn't submit that right now. Please call (305) 555-0100 directly.")
        return
      }
    } catch (e) {
      console.error("Inquiry POST exception:", e)
      alert("Network hiccup. Please call (305) 555-0100 directly.")
      return
    }

    form.classList.add("hidden")
    if (this.hasPartnerBannerTarget) this.partnerBannerTarget.classList.add("hidden")
    this.captureThanksTarget.classList.remove("hidden")

    // Reset context so the next capture starts fresh (modal stays open on success
    // so the user sees the thank-you; they close with the Close button or ESC).
    this._partnerId    = null
    this._partnerName  = null
    this._question     = null
    this._sourcePrompt = "capture"
  }

  // Bottom "Ask HosAlivio Anything" textarea — freeform question that drops into
  // the same conversation thread above and reveals the capture form.
  askAnything(event) {
    event.preventDefault()
    const text = this.anythingInputTarget.value.trim()
    if (!text) return

    // Scroll the HosAlivio stage into view so the user sees their question land there
    const thread = this.threadTarget
    thread.closest("section#hosalivio")?.scrollIntoView({ behavior: "smooth", block: "start" })

    // Remember their free-form text so submitCapture can include it.
    this._question     = text
    this._sourcePrompt = "ask_anything"

    // User bubble with their typed question
    this._appendUserBubble(text)
    this.anythingInputTarget.value = ""

    // HosAlivio's freeform reply, then open the modal so the user can leave contact info.
    this._appendHosalivioTyping().then(el => {
      setTimeout(() => {
        el.innerHTML = this._hosalivioFreeformReply(text)
        this._openCaptureModal()
      }, 500)
    })

    // Hide the starter chips once a real conversation has begun.
    if (this.hasChipsTarget) this.chipsTarget.classList.add("hidden")
  }

  // ─── internals ────────────────────────────────────────────────────

  _appendUserBubble(text) {
    const wrap = document.createElement("div")
    wrap.className = "flex justify-end"
    wrap.innerHTML = `
      <div class="max-w-[80%] bg-[#D97757] text-white rounded-2xl rounded-tr-md px-4 py-3 shadow-sm">
        <div class="text-[11px] uppercase tracking-[0.18em] font-bold mb-0.5 opacity-80">You</div>
        <div class="font-serif text-[14px] leading-relaxed">${escapeHtml(text)}</div>
      </div>`
    this.threadTarget.appendChild(wrap)
    this._scroll(wrap)
  }

  async _appendHosalivioTyping() {
    const wrap = document.createElement("div")
    wrap.className = "flex items-start gap-3"
    const botSrc = document.body.dataset.hosalivioBotSrc || "/assets/hosalivio_assistant.png"
    wrap.innerHTML = `
      <div class="w-12 h-12 rounded-full bg-white border border-[#EFECE6] overflow-hidden flex-shrink-0">
        <img src="${botSrc}" class="w-full h-full object-cover object-top scale-125 origin-top" alt="HosAlivio">
      </div>
      <div class="flex-1 bg-white rounded-2xl rounded-tl-md border border-[#EFECE6] p-4">
        <div class="text-[11px] uppercase tracking-[0.18em] font-bold text-[#1D1C1A] mb-1">
          HosAlivio <span class="text-[10px] text-[#6B665F] font-normal normal-case tracking-normal">· typing…</span>
        </div>
        <div class="flex gap-1 py-1">
          <span class="w-1.5 h-1.5 rounded-full bg-[#D9D5CD] animate-bounce" style="animation-delay:0ms"></span>
          <span class="w-1.5 h-1.5 rounded-full bg-[#D9D5CD] animate-bounce" style="animation-delay:120ms"></span>
          <span class="w-1.5 h-1.5 rounded-full bg-[#D9D5CD] animate-bounce" style="animation-delay:240ms"></span>
        </div>
      </div>`
    this.threadTarget.appendChild(wrap)
    this._scroll(wrap)
    return wrap
  }

  _swapTypingForAnswer(el, prompt) {
    const follows = (prompt.followups || [])
      .filter(id => !this._seen.has(id) && this.promptsValue[id])
      .map(id => this.promptsValue[id])

    const followupHtml = follows.length
      ? `<div class="mt-4 pt-3 border-t border-[#EFECE6]">
           <div class="text-[10px] uppercase tracking-widest text-[#6B665F] mb-2">Related</div>
           <div class="flex flex-wrap gap-2">
             ${follows.map(f => `
               <button type="button"
                 data-action="click->welcome#choosePrompt"
                 data-prompt-id="${f.id}"
                 class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-[#FBF9F5] border border-[#EFECE6] hover:border-[#D97757] hover:bg-[#FFF3EC] text-[12px] text-[#1D1C1A] transition">
                 <i class="${f.icon} text-[#D97757]"></i>${escapeHtml(f.label)}
               </button>`).join("")}
           </div>
         </div>`
      : ""

    // Universal soft-CTA unless the answer already routes to capture.
    const cta = prompt.open_capture
      ? ""
      : `<div class="mt-4 pt-3 border-t border-[#EFECE6]">
           <button type="button"
             data-action="click->welcome#choosePrompt"
             data-prompt-id="speak"
             class="inline-flex items-center gap-1.5 text-[12px] text-[#D97757] hover:text-[#c46a4b]">
             <i class="ri-customer-service-2-line"></i> Talk to an admissions coordinator about this
             <i class="ri-arrow-right-s-line"></i>
           </button>
         </div>`

    const botSrcReply = document.body.dataset.hosalivioBotSrc || "/assets/hosalivio_assistant.png"
    el.innerHTML = `
      <div class="w-12 h-12 rounded-full bg-white border border-[#EFECE6] overflow-hidden flex-shrink-0">
        <img src="${botSrcReply}" class="w-full h-full object-cover object-top scale-125 origin-top" alt="HosAlivio">
      </div>
      <div class="flex-1 bg-white rounded-2xl rounded-tl-md border border-[#EFECE6] p-4">
        <div class="text-[11px] uppercase tracking-[0.18em] font-bold text-[#1D1C1A] mb-2">
          HosAlivio <span class="text-[10px] text-[#6B665F] font-normal normal-case tracking-normal">· Admissions concierge</span>
        </div>
        <div class="font-serif text-[14px] text-[#1D1C1A] leading-relaxed whitespace-pre-wrap">${renderAnswer(prompt.answer)}</div>
        ${cta}
        ${followupHtml}
      </div>`

    if (prompt.open_capture && this.hasCaptureTarget) {
      this._sourcePrompt = prompt.id || "capture"
      this._partnerId    = null
      this._partnerName  = null
      this._openCaptureModal()
    } else {
      this._scroll(el)
    }
  }

  _scroll(el) {
    setTimeout(() => el.scrollIntoView({ behavior: "smooth", block: "center" }), 60)
  }

  _hosalivioFreeformReply() {
    const botSrcFree = document.body.dataset.hosalivioBotSrc || "/assets/hosalivio_assistant.png"
    return `
      <div class="w-12 h-12 rounded-full bg-white border border-[#EFECE6] overflow-hidden flex-shrink-0">
        <img src="${botSrcFree}" class="w-full h-full object-cover object-top scale-125 origin-top" alt="HosAlivio">
      </div>
      <div class="flex-1 bg-white rounded-2xl rounded-tl-md border border-[#EFECE6] p-4">
        <div class="text-[11px] uppercase tracking-[0.18em] font-bold text-[#1D1C1A] mb-2">
          HosAlivio <span class="text-[10px] text-[#6B665F] font-normal normal-case tracking-normal">· Admissions concierge</span>
        </div>
        <div class="font-serif text-[14px] text-[#1D1C1A] leading-relaxed">
          Thank you for sharing — that deserves a real person, not a canned answer. Leave a zip code and a way to reach you just below, and a coordinator will call back shortly. I'll make sure they have your question in front of them before they dial.
        </div>
        <div class="mt-4 pt-3 border-t border-[#EFECE6] text-[11px] text-[#6B665F]">
          <i class="ri-shield-check-line"></i> Your message stays within HosAlivio. Nothing is shared beyond the admissions coordinator who calls you back.
        </div>
      </div>`
  }
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, c => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[c]))
}

// Lightweight answer renderer: bullets, **bold**, newlines — no full markdown.
function renderAnswer(text) {
  const safe = escapeHtml(text)
  return safe
    .replace(/\*\*(.+?)\*\*/g, '<strong class="text-[#1D1C1A]">$1</strong>')
    .replace(/^•\s?/gm, '<span class="text-[#D97757]">•</span>&nbsp;')
}
