import { Controller } from "@hotwired/stimulus"

// Connects to <main data-controller="patient-chat" data-patient-chat-patient-id-value="…">
export default class extends Controller {
  static targets = ["input", "feed", "status", "quickActions", "mic", "audienceToggle", "form", "placeholderOverlay", "recordButton", "recordTimer"]
  static values  = {
    patientId: String,
    lang:      { type: String, default: "en-US" },
    timezone:  { type: String, default: "America/New_York" }
  }

  connect() {
    this._currentUrgency = "normal"
    this._openCable()
    this._initSpeech()
    this._scrollToBottom()
  }

  disconnect() {
    this._ws?.close()
    try { this._speech?.stop() } catch (_) {}
    this._clearTyping()
  }

  toggleQuickActions() {
    this.quickActionsTarget.classList.toggle("hidden")
  }

  // ── Voice-note recording (MediaRecorder) ─────────────────────────
  // Tap once to start recording, tap again to stop + send. The pending
  // audio Blob lives on the controller until send() picks it up and ships
  // it as part of a multipart FormData submit (instead of the usual JSON).
  async toggleRecord() {
    if (this._mediaRecorder && this._mediaRecorder.state === "recording") {
      this._stopRecording()
    } else {
      await this._startRecording()
    }
  }

  async _startRecording() {
    let stream
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (err) {
      console.warn("[patient-chat] mic permission denied:", err)
      return
    }
    this._mediaStream = stream
    this._audioChunks = []
    const mime = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]
                   .find((c) => MediaRecorder.isTypeSupported(c)) || ""
    this._mediaRecorder = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream)
    this._mediaRecorder.ondataavailable = (e) => { if (e.data && e.data.size > 0) this._audioChunks.push(e.data) }
    this._mediaRecorder.onstop = () => this._finalizeRecording()
    this._mediaRecorder.start(1000)
    this._recordStartMs = Date.now()
    this._paintRecord("recording")
    this._startRecordTimer()
  }

  _stopRecording() {
    if (this._mediaRecorder) {
      try { this._mediaRecorder.stop() } catch (_) {}
    }
    this._stopRecordTimer()
  }

  _finalizeRecording() {
    const type = this._mediaRecorder.mimeType || "audio/webm"
    const ext  = type.includes("ogg") ? "ogg" : (type.includes("mp4") ? "m4a" : "webm")
    const blob = new Blob(this._audioChunks, { type })
    this._pendingAudio = new File([blob], `voice-${Date.now()}.${ext}`, { type })
    if (this._mediaStream) {
      this._mediaStream.getTracks().forEach((t) => { try { t.stop() } catch (_) {} })
      this._mediaStream = null
    }
    this._paintRecord("idle")
    // Auto-send the voice note immediately — same UX as iMessage / WhatsApp.
    // The user already had a chance to "cancel" by re-tapping while recording.
    this.send(new Event("submit", { cancelable: true }))
  }

  _startRecordTimer() {
    if (this.hasRecordTimerTarget) {
      this.recordTimerTarget.classList.remove("hidden")
      this.recordTimerTarget.textContent = "0:00"
    }
    this._recordTimerInterval = setInterval(() => {
      if (!this.hasRecordTimerTarget) return
      const sec = Math.floor((Date.now() - this._recordStartMs) / 1000)
      this.recordTimerTarget.textContent = `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, "0")}`
    }, 250)
  }

  _stopRecordTimer() {
    if (this._recordTimerInterval) clearInterval(this._recordTimerInterval)
    this._recordTimerInterval = null
    if (this.hasRecordTimerTarget) {
      this.recordTimerTarget.classList.add("hidden")
      this.recordTimerTarget.textContent = ""
    }
  }

  _paintRecord(state) {
    if (!this.hasRecordButtonTarget) return
    const btn  = this.recordButtonTarget
    const icon = btn.querySelector("i")
    btn.dataset.state = state
    if (state === "recording") {
      btn.classList.add("bg-[#C1403A]", "text-white", "animate-pulse")
      btn.classList.remove("bg-[#FBF9F5]", "text-[#C1403A]")
      if (icon) { icon.classList.remove("ri-record-circle-line"); icon.classList.add("ri-stop-circle-line") }
    } else {
      btn.classList.remove("bg-[#C1403A]", "text-white", "animate-pulse")
      btn.classList.add("bg-[#FBF9F5]", "text-[#C1403A]")
      if (icon) { icon.classList.remove("ri-stop-circle-line"); icon.classList.add("ri-record-circle-line") }
    }
  }

  // Hide the styled placeholder overlay as soon as the user types, show
  // it again when the input is empty. Bound to the input's `input` event.
  refreshPlaceholderOverlay() {
    if (!this.hasPlaceholderOverlayTarget || !this.hasInputTarget) return
    this.placeholderOverlayTarget.classList.toggle("hidden", this.inputTarget.value.length > 0)
  }

  // Audience toggle: clinicians flip between family-facing and team-only.
  // The button + the wrapping form both carry data-audience so Tailwind
  // data-* variants restyle the input as the audience changes (warm orange
  // for family, dashed grey for the team-only "side channel").
  toggleAudience() {
    if (!this.hasAudienceToggleTarget) return
    const next = this.audienceToggleTarget.dataset.audience === "team" ? "family" : "team"
    this.audienceToggleTarget.dataset.audience = next
    if (this.hasFormTarget) this.formTarget.dataset.audience = next
    // Placeholder text swaps via CSS (group-data-[audience=team]/audience:*)
    // so we don't touch the input here — keeps the styled overlay in sync.
  }

  _isInternal() {
    return this.hasAudienceToggleTarget && this.audienceToggleTarget.dataset.audience === "team"
  }

  quickAction(event) {
    const btn = event.currentTarget
    this.inputTarget.value = btn.dataset.template || ""
    this._currentUrgency   = btn.dataset.urgency  || "normal"
    this.quickActionsTarget.classList.add("hidden")
    this.inputTarget.focus()
  }

  // ── Voice input (Web Speech API) ─────────────────────────────────
  // Tap-to-start / tap-to-pause toggle. Transcribes continuously so the
  // user can talk in full sentences without it cutting off. Resume picks
  // up where they left off (the previous transcript becomes the new
  // start-text on the next start).
  toggleMic() {
    if (!this._speech) return
    if (this._listening) {
      this._userStopped = true   // signal: don't auto-restart from onend
      try { this._speech.stop() } catch (_) {}
    } else {
      this._micStartText = this.inputTarget.value
      this._userStopped  = false
      try { this._speech.start() } catch (_) { /* already running */ }
    }
  }

  _initSpeech() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition
    if (!SR) {
      if (this.hasMicTarget) this.micTarget.title = "Voice input not supported in this browser"
      return
    }
    const r = new SR()
    r.lang           = this.langValue || "en-US"
    r.interimResults = true
    r.continuous     = true   // keep listening until the user taps to stop

    r.onstart  = () => { this._listening = true;  this._paintMic(true)  }
    r.onerror  = (e) => { this._listening = false; this._paintMic(false); console.warn("speech error:", e.error) }
    r.onend    = () => {
      this._listening = false
      this._paintMic(false)
      this._usedVoice = true
      // Continuous mode can end on a long silence even when the user
      // didn't tap stop. If they didn't tap stop, restart so the session
      // feels like a single uninterrupted recording.
      if (!this._userStopped) {
        try { r.start() } catch (_) {}
      }
    }
    r.onresult = (e) => {
      // Build the full transcript from every result so interim updates
      // correctly replace earlier interim text within the same session.
      let transcript = ""
      for (let i = 0; i < e.results.length; i++) {
        transcript += e.results[i][0].transcript
      }
      this.inputTarget.value = (this._micStartText ? this._micStartText + " " : "") + transcript
      this.refreshPlaceholderOverlay()
    }
    this._speech = r
    if (this.hasMicTarget) {
      this.micTarget.disabled = false
      this.micTarget.title = "Tap to start dictating — tap again to pause"
      this.micTarget.classList.remove("cursor-not-allowed", "text-[#B9B4AB]")
      this.micTarget.classList.add("text-[#D97757]", "hover:bg-[#FBF9F5]")
    }
  }

  _paintMic(on) {
    if (!this.hasMicTarget) return
    const icon = this.micTarget.querySelector("i")
    if (on) {
      this.micTarget.classList.add("bg-[#D97757]", "text-white", "animate-pulse")
      this.micTarget.classList.remove("text-[#D97757]")
      if (icon) { icon.classList.remove("ri-mic-line"); icon.classList.add("ri-mic-fill") }
    } else {
      this.micTarget.classList.remove("bg-[#D97757]", "text-white", "animate-pulse")
      this.micTarget.classList.add("text-[#D97757]")
      if (icon) { icon.classList.remove("ri-mic-fill"); icon.classList.add("ri-mic-line") }
    }
  }

  async send(event) {
    event.preventDefault()
    const text  = this.inputTarget.value.trim()
    const audio = this._pendingAudio
    if (!text && !audio) return

    const csrfMeta = document.querySelector("meta[name='csrf-token']")
    const csrf     = csrfMeta ? csrfMeta.content : ""

    // Family viewers post to /family_messages (Lucia-triaged); clinicians
    // post to /clinician_messages (saved as themselves with their real name).
    const isFamily = document.body.dataset.viewerFamily === "true"
    const url      = isFamily ? "/api/v1/family_messages" : "/api/v1/clinician_messages"
    const internal = this._isInternal()

    // Clear input + clear pending audio + schedule typing dots BEFORE
    // the await so feedback is immediate. The 800ms delay lets the user's
    // own bubble Cable-echo land first.
    this.inputTarget.value = ""
    this.refreshPlaceholderOverlay()
    this._pendingAudio = null
    const sentUrgency = this._currentUrgency
    const wasVoice    = this._usedVoice || !!audio
    this._currentUrgency = "normal"
    this._usedVoice = false
    if (isFamily && !internal) this._scheduleTyping(800)

    let resp
    if (audio) {
      // Multipart: voice note (with optional text caption).
      const fd = new FormData()
      fd.append("patient_id", this.patientIdValue)
      fd.append("text",       text)
      fd.append("urgency",    sentUrgency)
      fd.append("source",     "voice")
      fd.append("internal",   internal ? "true" : "false")
      fd.append("audio",      audio, audio.name)
      resp = await fetch(url, {
        method:  "POST",
        headers: { "Accept": "application/json", "X-CSRF-Token": csrf },
        body:    fd
      })
    } else {
      // JSON path — no audio, normal typed message.
      resp = await fetch(url, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": csrf
        },
        body: JSON.stringify({
          patient_id: this.patientIdValue,
          text:       text,
          urgency:    sentUrgency,
          source:     wasVoice ? "voice" : "text",
          internal:   internal
        })
      })
    }

    if (!resp.ok) {
      const err = await resp.text()
      console.error("send failed:", resp.status, err)
      this._clearTyping()
    }
  }

  // ── Typing indicator ─────────────────────────────────────────────
  _scheduleTyping(delayMs) {
    this._clearTyping()
    this._typingTimer = setTimeout(() => this._showTyping(), delayMs)
  }

  _showTyping() {
    if (this._typingEl) return
    const botSrc = document.body.dataset.hosalivioBotSrc || "/assets/hosalivio_assistant.png"
    const wrap = document.createElement("div")
    wrap.className = "max-w-2xl mx-auto opacity-0 transition-opacity duration-300"
    wrap.innerHTML = `
      <div class="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-[#EFECE6] border border-[#EFECE6] ring-1 ring-dashed ring-[#B9B4AB]">
        <div class="w-7 h-7 rounded-full bg-white border border-[#EFECE6] overflow-hidden flex-shrink-0">
          <img src="${botSrc}" class="w-full h-full object-cover object-top scale-125 origin-top" alt="HosAlivio">
        </div>
        <span class="text-[10px] font-bold uppercase tracking-widest text-[#6B665F]">HosAlivio Assist</span>
        <span class="text-[10px] text-[#6B665F]">is thinking</span>
        <div class="flex items-center gap-1 ml-0.5">
          <span class="w-1.5 h-1.5 bg-[#6B665F] rounded-full animate-bounce" style="animation-delay:0ms;animation-duration:1.4s"></span>
          <span class="w-1.5 h-1.5 bg-[#6B665F] rounded-full animate-bounce" style="animation-delay:280ms;animation-duration:1.4s"></span>
          <span class="w-1.5 h-1.5 bg-[#6B665F] rounded-full animate-bounce" style="animation-delay:560ms;animation-duration:1.4s"></span>
        </div>
      </div>
    `
    this.feedTarget.appendChild(wrap)
    requestAnimationFrame(() => { wrap.style.opacity = "1" })
    this._scrollToBottom()
    this._typingEl = wrap

    // Fallback: if no reply lands within 30s, swap the dots for a calm message.
    this._typingFallback = setTimeout(() => this._showTypingFallback(), 30000)
  }

  _showTypingFallback() {
    if (!this._typingEl) return
    const botSrc = document.body.dataset.hosalivioBotSrc || "/assets/hosalivio_assistant.png"
    this._typingEl.innerHTML = `
      <div class="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-[#EFECE6] border border-[#EFECE6] ring-1 ring-dashed ring-[#B9B4AB]">
        <div class="w-7 h-7 rounded-full bg-white border border-[#EFECE6] overflow-hidden flex-shrink-0">
          <img src="${botSrc}" class="w-full h-full object-cover object-top scale-125 origin-top" alt="HosAlivio">
        </div>
        <span class="text-[12px] text-[#3A3936]">Your care team has been notified — we'll reply as soon as we can.</span>
      </div>
    `
  }

  _clearTyping() {
    if (this._typingTimer) { clearTimeout(this._typingTimer); this._typingTimer = null }
    if (this._typingFallback) { clearTimeout(this._typingFallback); this._typingFallback = null }
    if (this._typingEl) { this._typingEl.remove(); this._typingEl = null }
  }

  // ── Date separators ─────────────────────────────────────────────
  _maybeInsertDateSeparator(iso) {
    // Use the patient's branch timezone so the day-boundary matches what
    // the server-rendered separators decided. Both lastDay and noteDay are
    // already YYYY-MM-DD strings — compare them directly. Re-parsing via
    // `new Date(yyyy-mm-dd)` would treat the string as UTC midnight, which
    // shifts to the previous day in any negative-offset timezone (EDT, etc.)
    // and falsely triggers a "new day" separator on each Cable message.
    const tz = this.timezoneValue
    const noteDay = new Date(iso).toLocaleDateString("en-CA", { timeZone: tz })
    const lastDay = this._lastNoteDate || this.feedTarget.dataset.lastDate
    if (lastDay === noteDay) return
    this._appendDateSeparator(new Date(iso))
    this._lastNoteDate = noteDay
  }

  _appendHuddleBubble(n) {
    const time = new Date(n.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", timeZone: this.timezoneValue })
    const speakerName = n.author_name || this._roleLabel(n.author_role)
    const speakerSub  = n.author_subtitle || ""
    const labelColor  = this._labelColor(n.author_role)
    const roleIcon    = this._roleIcon(n.author_role)
    const urgencyPill = n.urgency === "urgent"
      ? `<span class="text-[10px] font-bold px-2 py-0.5 rounded bg-[#D97757] text-white tracking-wider flex-shrink-0">URGENT</span>`
      : ""

    const bubble = document.createElement("div")
    bubble.className = "max-w-2xl ml-auto bg-[#FBF9F5] border border-dashed border-[#B9B4AB] rounded-3xl px-5 py-4 opacity-0 transition-opacity duration-300"
    bubble.title = `Internal note · ${speakerName} · ${time}`
    bubble.innerHTML = `
      <div class="flex items-center justify-between mb-1 gap-2">
        <div class="min-w-0 flex items-center gap-2.5">
          <i class="${roleIcon} text-[14px]" style="color: ${labelColor};"></i>
          <div class="min-w-0">
            <div class="inline-flex items-center gap-1.5 text-[13px] font-medium" style="color: ${labelColor};">
              <span class="truncate" data-role="name"></span>
            </div>
            ${speakerSub ? `<div class="text-[9px] uppercase tracking-[0.18em] text-[#6B665F] font-mono mt-0.5" data-role="sub"></div>` : ""}
          </div>
        </div>
        ${urgencyPill}
      </div>
      <p class="font-serif text-[15px] text-[#3A3936] leading-relaxed whitespace-pre-wrap break-words [overflow-wrap:anywhere] mt-1"></p>
      <div class="flex items-center justify-between mt-2 gap-2">
        <span class="inline-flex items-center gap-1 text-[9px] uppercase tracking-[0.18em] text-[#6B665F] bg-white border border-[#B9B4AB] rounded-full px-2 py-0.5"
              title="Hidden from the family — only the IDG sees this.">
          <i class="ri-team-line text-[10px]"></i> Team only
        </span>
        <div class="text-[10px] text-[#6B665F] font-mono">${time}</div>
      </div>
    `
    bubble.querySelector('[data-role="name"]').textContent = speakerName
    if (speakerSub) bubble.querySelector('[data-role="sub"]').textContent = speakerSub
    bubble.querySelector("p").textContent = n.body
    this.feedTarget.appendChild(bubble)
    requestAnimationFrame(() => { bubble.style.opacity = "1" })
    this._scrollToBottom()
  }

  _appendActionBanner(n) {
    const time = new Date(n.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", timeZone: this.timezoneValue })
    const label  = n.action_payload.label
    const detail = n.action_payload.detail
    const role   = String(n.author_role || "").replace(/_/g, " ").toUpperCase()
    const urgencyTag = n.urgency === "crisis"
      ? `<span class="ml-1 text-[#C1403A]">· Crisis</span>`
      : n.urgency === "urgent"
      ? `<span class="ml-1 text-[#D97757]">· Urgent</span>`
      : ""

    const wrap = document.createElement("div")
    wrap.className = "max-w-3xl flex items-center gap-3 px-4 py-2.5 rounded-xl border border-[#7FB99A] bg-[#E6F0EA] opacity-0 transition-opacity duration-300"
    wrap.title = `Action by ${role} · ${time}`
    wrap.innerHTML = `
      <i class="ri-checkbox-circle-fill text-[#2F6F4E] text-[18px] flex-shrink-0"></i>
      <div class="min-w-0 flex-1">
        <div class="text-[10px] uppercase tracking-[0.18em] text-[#2F6F4E] font-bold">
          <span data-role="label"></span>${urgencyTag}
        </div>
        <div data-role="detail" class="text-[13px] text-[#1D1C1A] truncate mt-0.5"></div>
      </div>
      <div class="text-[10px] text-[#6B665F] font-mono flex-shrink-0">${time}</div>
    `
    wrap.querySelector('[data-role="label"]').textContent = label
    const detailEl = wrap.querySelector('[data-role="detail"]')
    if (detail) { detailEl.textContent = detail } else { detailEl.remove() }
    this.feedTarget.appendChild(wrap)
    requestAnimationFrame(() => { wrap.style.opacity = "1" })
    this._scrollToBottom()
  }

  _appendAuditLog(n) {
    const time = new Date(n.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", timeZone: this.timezoneValue })
    const role = String(n.author_role || "").replace(/_/g, " ")
    const urgencyPill = n.urgency === "crisis"
      ? `<span class="inline-flex items-center gap-1 text-[9px] font-bold text-[#C1403A] uppercase tracking-wider"><span class="w-1.5 h-1.5 rounded-full bg-[#C1403A] animate-pulse"></span>crisis</span>`
      : n.urgency === "urgent"
      ? `<span class="inline-flex items-center gap-1 text-[9px] font-bold text-[#D97757] uppercase tracking-wider"><span class="w-1.5 h-1.5 rounded-full bg-[#D97757]"></span>urgent</span>`
      : ""

    const det = document.createElement("details")
    det.className = "group max-w-3xl opacity-0 transition-opacity duration-300"
    det.innerHTML = `
      <summary class="cursor-pointer list-none flex items-center gap-2 py-1.5 px-3 text-[11px] text-[#6B665F] hover:bg-[#FBF9F5] rounded-md transition [&::-webkit-details-marker]:hidden">
        <i class="ri-arrow-right-s-line group-open:rotate-90 transition-transform"></i>
        <i class="ri-file-list-3-line text-[#B9B4AB]"></i>
        <span class="uppercase tracking-[0.18em] text-[9px] font-bold">Internal · ${role} trace</span>
        ${urgencyPill}
        <span class="text-[10px] text-[#B9B4AB] font-mono ml-auto">${time}</span>
      </summary>
      <div class="ml-6 mt-1 mb-2 py-2 px-3 bg-[#FBF9F5] border-l-2 border-[#D9D5CD] rounded-r-md">
        <div data-role="body" class="text-[12px] text-[#3A3936] leading-relaxed whitespace-pre-wrap break-words [overflow-wrap:anywhere]"></div>
      </div>
    `
    // Mirror the server-side render_audit_body helper: escape HTML,
    // then turn @Name tokens into clickable mention buttons.
    const bodyEl = det.querySelector('[data-role="body"]')
    bodyEl.innerHTML = this._renderAuditBodyHTML(n.body)
    this.feedTarget.appendChild(det)
    requestAnimationFrame(() => { det.style.opacity = "1" })
    this._scrollToBottom()
  }

  // HTML-escape + wrap @Name tokens as clickable mention buttons.
  // Mirrors app/helpers/application_helper.rb#render_audit_body — and
  // skips the viewer's own name (rendered as a muted span) so they
  // can't tap to ping themselves.
  _renderAuditBodyHTML(body) {
    if (!body) return ""
    const me = (document.body.dataset.viewerFirstName || "").toLowerCase()
    const esc = String(body).replace(/[&<>"']/g, (c) => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
    })[c])
    return esc.replace(/@(\w+)/g, (_, name) => {
      if (me && name.toLowerCase() === me) {
        return `<span class="font-medium text-[#6B665F]" title="That's you">@${name}</span>`
      }
      return `<button type="button"
                      class="font-medium text-[#D97757] hover:underline cursor-pointer"
                      data-action="click->patient-chat#mention"
                      data-mention="${name}"
                      title="Reply to ${name} (private team note)">@${name}</button>`
    })
  }

  // Stimulus action: clicking an @Name in an audit row inserts the
  // mention into the input + flips the visibility toggle to internal.
  // Esther sees "Notified: @Pascal (RN)" → taps @Pascal → input becomes
  // "@Pascal " with audience locked to team-only, ready for the dose
  // discussion she's about to type. No-ops on self-mention as defense
  // (server should already render those as plain spans).
  mention(event) {
    const name = event.currentTarget?.dataset?.mention
    if (!name || !this.hasInputTarget) return
    const me = (document.body.dataset.viewerFirstName || "").toLowerCase()
    if (me && name.toLowerCase() === me) return
    if (this.hasAudienceToggleTarget && this.audienceToggleTarget.dataset.audience !== "team") {
      this.toggleAudience()
    }
    const current = this.inputTarget.value.trimStart()
    const prefix = `@${name} `
    if (!current.startsWith(prefix)) {
      this.inputTarget.value = prefix + current
    }
    this.inputTarget.focus()
    // Move cursor to the end so they can just start typing.
    const len = this.inputTarget.value.length
    this.inputTarget.setSelectionRange(len, len)
    this.refreshPlaceholderOverlay()
  }

  _appendDateSeparator(date) {
    const sep = document.createElement("div")
    sep.className = "flex items-center justify-center pt-2 pb-1"
    sep.innerHTML = `<div class="px-3 py-1 text-[10px] uppercase tracking-[0.18em] text-[#6B665F] bg-[#FBF9F5] border border-[#EFECE6] rounded-full font-medium">${this._dateLabel(date)}</div>`
    this.feedTarget.appendChild(sep)
  }

  _dateLabel(date) {
    const tz = this.timezoneValue
    const fmt = (d) => d.toLocaleDateString("en-CA", { timeZone: tz })  // YYYY-MM-DD
    const todayStr  = fmt(new Date())
    const targetStr = fmt(date)
    if (todayStr === targetStr) return "Today"
    const today  = new Date(todayStr)
    const target = new Date(targetStr)
    const diffDays = Math.round((today - target) / (1000 * 60 * 60 * 24))
    if (diffDays === 1)  return "Yesterday"
    if (diffDays > 1 && diffDays < 7) {
      return date.toLocaleDateString([], { weekday: "long", timeZone: tz })
    }
    const sameYear = today.getFullYear() === target.getFullYear()
    return date.toLocaleDateString([], sameYear
      ? { month: "long", day: "numeric", timeZone: tz }
      : { month: "long", day: "numeric", year: "numeric", timeZone: tz })
  }

  // ──────────────────────────────────────────────────────────────────
  _openCable() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:"
    const ws    = new WebSocket(`${proto}//${location.host}/cable`)
    this._ws    = ws

    ws.onopen = () => {
      this._setStatus("connected", "#2F6F4E")
      ws.send(JSON.stringify({
        command: "subscribe",
        identifier: JSON.stringify({ channel: "PatientChannel", patient_id: this.patientIdValue })
      }))
    }
    ws.onclose = () => this._setStatus("disconnected", "#C1403A")
    ws.onerror = () => this._setStatus("error",        "#C1403A")

    ws.onmessage = (msg) => {
      const data = JSON.parse(msg.data)
      if (["ping", "welcome", "confirm_subscription"].includes(data.type)) return
      const payload = data.message
      if (!payload || payload.kind !== "note") return
      this._appendNote(payload)
    }
  }

  _setStatus(text, color) {
    if (!this.hasStatusTarget) return
    this.statusTarget.textContent    = text
    this.statusTarget.style.color    = color
  }

  _appendNote(n) {
    // Skip clinician-only notes (audit logs, agent rationales) when the
    // viewer is a family user — those belong on the Mission Stage and
    // patient chart for clinicians, never in the family chat thread.
    if (n.clinician_only && document.body.dataset.viewerFamily === "true") return

    // Clinician-only notes for clinicians, in priority order:
    //   1. action banner ([ACTION:...] marker) — green success bar
    //   2. IDG huddle bubble (real human author) — dashed muted bubble
    //   3. audit rationale (no human author) — collapsed audit row
    if (n.clinician_only) {
      if (n.action_payload) {
        this._appendActionBanner(n)
      } else if (n.author_user_id) {
        this._appendHuddleBubble(n)
      } else {
        this._appendAuditLog(n)
      }
      return
    }

    // The next non-family message means a reply has arrived — clear the
    // typing indicator before rendering the actual bubble.
    if (n.author_role !== "family") this._clearTyping()

    // Day-change separator — drop a "Today / Yesterday / Monday / Apr 22"
    // pill in the feed when this note crosses into a new calendar day.
    this._maybeInsertDateSeparator(n.created_at)

    const bubble      = document.createElement("div")
    const labelColor  = n.ai_authored ? "#6B665F" : this._labelColor(n.author_role)
    const roleIcon    = n.ai_authored ? "ri-robot-2-line" : this._roleIcon(n.author_role)
    const isFamily    = n.author_role === "family"
    const align       = isFamily ? "" : "ml-auto"
    const bg          = isFamily ? "bg-[#FFF3EC]" : "bg-[#E6F0EE]"
    const aiRing      = n.ai_authored ? "ring-1 ring-dashed ring-[#B9B4AB]" : ""

    // Real-name-first: show the human's actual name when available; fall back
    // to the backend-supplied label ("HosAlivio Assist") only for AI notes.
    const speakerName = n.author_name || this._roleLabel(n.author_role)

    // Warmer subtitle for family viewers; clinicians see the raw role.
    const viewerIsFamily = document.body.dataset.viewerFamily === "true"
    const familyLabels = {
      rn: "Your RN", md: "Your doctor", social_worker: "Your social worker",
      chaplain: "Your chaplain", aide: "Your aide", don: "Your DON",
      admissions: "Your care coordinator", pharmacy: "Your pharmacist",
      dme: "Your equipment team", insurance: "Your benefits coordinator"
    }
    let speakerSub = n.author_subtitle || ""
    if (viewerIsFamily && !n.ai_authored && familyLabels[n.author_role]) {
      speakerSub = familyLabels[n.author_role]
    } else if (viewerIsFamily && n.ai_authored) {
      speakerSub = "Automated reply on behalf of your care team"
    }

    const timeLabel = new Date(n.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", timeZone: this.timezoneValue })
    const bubbleTitle = viewerIsFamily
      ? `Sent ${timeLabel}`
      : n.ai_authored
      ? `AI auto-draft on ${String(n.author_role).toUpperCase()} role · ${timeLabel}`
      : `${speakerName} via ${String(n.author_role).toUpperCase()} role · ${timeLabel}`

    const urgencyPill = n.urgency === "crisis"
      ? `<span class="text-[10px] font-bold px-2 py-0.5 rounded bg-[#C1403A] text-white tracking-wider">CRISIS</span>`
      : n.urgency === "urgent"
      ? `<span class="text-[10px] font-bold px-2 py-0.5 rounded bg-[#D97757] text-white tracking-wider">URGENT</span>`
      : ""

    bubble.className = `max-w-2xl min-w-0 ${align} ${bg} border border-[#EFECE6] ${aiRing} rounded-3xl px-5 py-4 opacity-0 transition-opacity duration-300`
    bubble.setAttribute("title", bubbleTitle)

    const subEl = speakerSub
      ? `<div class="text-[9px] uppercase tracking-[0.18em] text-[#6B665F] font-mono mt-0.5"></div>`
      : ""

    const aiAvatar = n.ai_authored
      ? `<div class="w-10 h-10 rounded-full overflow-hidden flex-shrink-0 bg-white border border-[#EFECE6]">
           <img src="${document.body.dataset.hosalivioBotSrc || '/assets/hosalivio_assistant.png'}" class="w-full h-full object-cover object-top scale-125 origin-top" alt="HosAlivio Assistant">
         </div>`
      : `<i class="${roleIcon} text-[14px]"></i>`

    const sentToFamilyChip = (n.ai_authored && !viewerIsFamily)
      ? `<span class="inline-flex items-center gap-1 text-[9px] uppercase tracking-[0.18em] text-[#6B665F] bg-[#FBF9F5] border border-[#EFECE6] rounded-full px-2 py-0.5" title="This message was sent to the family — they've already read it.">
           <i class="ri-send-plane-line text-[10px]"></i> Sent to family
         </span>`
      : `<span></span>`

    bubble.innerHTML = `
      <div class="flex items-center justify-between mb-1 gap-2">
        <div class="min-w-0 flex items-center gap-2">
          ${aiAvatar}
          <div class="min-w-0">
            <div class="inline-flex items-center gap-1.5 text-[13px] font-medium" style="color: ${labelColor};">
              <span class="truncate" data-role="name"></span>
            </div>
            ${subEl}
          </div>
        </div>
        ${urgencyPill}
      </div>
      <p data-role="body" class="font-serif text-[16px] text-[#1D1C1A] leading-relaxed whitespace-pre-wrap break-words [overflow-wrap:anywhere] mt-1"></p>
      ${n.audio_url ? `<audio src="${n.audio_url}" controls class="w-full h-9 mt-2"></audio>` : ""}
      <div class="flex items-center justify-between mt-2 gap-2">
        ${sentToFamilyChip}
        <div class="text-[10px] text-[#6B665F] font-mono">${new Date(n.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", timeZone: this.timezoneValue })}</div>
      </div>
    `
    bubble.querySelector('[data-role="name"]').textContent = speakerName
    if (speakerSub) bubble.querySelector(`.text-\\[9px\\]`).textContent = speakerSub
    const bodyEl = bubble.querySelector('[data-role="body"]')
    if (n.body) {
      bodyEl.textContent = n.body
    } else {
      bodyEl.remove()
    }
    this.feedTarget.appendChild(bubble)
    requestAnimationFrame(() => { bubble.style.opacity = "1" })
    this._scrollToBottom()
  }

  _roleIcon(role) {
    return ({
      family: "ri-user-heart-line", rn: "ri-nurse-line", md: "ri-stethoscope-line",
      social_worker: "ri-team-line", chaplain: "ri-hand-heart-line",
      pharmacy: "ri-capsule-line", aide: "ri-user-2-line", don: "ri-award-line",
      dme: "ri-tools-line", insurance: "ri-bank-card-line",
      admissions: "ri-customer-service-2-line",
      front_door_inbound: "ri-customer-service-2-line", system: "ri-flashlight-line"
    })[role] || "ri-user-line"
  }

  _scrollToBottom() {
    if (!this.hasFeedTarget) return
    this.feedTarget.scrollTop = this.feedTarget.scrollHeight
  }

  _roleLabel(role) {
    return ({
      family: "Family", rn: "RN", md: "MD",
      social_worker: "Social Worker", chaplain: "Chaplain",
      pharmacy: "Pharmacy", aide: "Aide", don: "DON",
      dme: "DME", insurance: "Insurance",
      admissions: "Front Door",
      front_door_inbound: "Front Door", system: "System"
    })[role] || (role || "").toUpperCase()
  }

  _labelColor(role) {
    return ({
      family: "#D97757", rn: "#2F6F4E", md: "#2B4A7A",
      social_worker: "#7A4A8C", chaplain: "#8C6A2F",
      pharmacy: "#5A2F7A", aide: "#3A6B6B", don: "#1D1C1A",
      dme: "#6B5A2F", insurance: "#4A4A6B",
      admissions: "#1D1C1A",
      front_door_inbound: "#1D1C1A", system: "#6B665F"
    })[role] || "#6B665F"
  }
}
