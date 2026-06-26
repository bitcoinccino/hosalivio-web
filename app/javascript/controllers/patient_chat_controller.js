import { Controller } from "@hotwired/stimulus"

// Connects to <main data-controller="patient-chat" data-patient-chat-patient-id-value="…">
export default class extends Controller {
  static targets = ["input", "feed", "status", "quickActions", "mic", "micIcon", "micWave", "form", "placeholderOverlay", "recordButton", "recordTimer", "composer"]
  static values  = {
    patientId:   String,
    lang:        { type: String, default: "en-US" },
    timezone:    { type: String, default: "America/New_York" },
    focusNoteId: { type: String, default: "" }
  }

  connect() {
    this._currentUrgency = "normal"
    this._openCable()
    this._initSpeech()
    this._scrollToBottom()
    this._focusNoteFromDeepLink()
  }

  // Escape a raw message body, then highlight @mentions — @HosAlivio with the
  // brand color + bot icon, any other @handle as a colored name. Mirrors the
  // server-side IcdHelper#highlight_chat_mentions so live and reloaded
  // messages look the same. Escapes BEFORE injecting spans (no XSS surface).
  _mentionHTML(text) {
    const esc = String(text == null ? "" : text)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
    return esc.replace(/@(\w+)/g, (_m, handle) => {
      if (handle.toLowerCase() === "hosalivio") {
        return `<span class="inline-flex items-center gap-0.5 font-semibold text-[#D97757]"><i class="ri-heart-pulse-line text-[11px]"></i>@${handle}</span>`
      }
      return `<span class="font-semibold text-[#2B4A7A]">@${handle}</span>`
    })
  }

  // Deep-link from a notification (?note=<id>): scroll the targeted message
  // into view and flash a highlight ring. Works for root notes and replies
  // (both carry data-note-id). No-ops if the note isn't in the loaded window.
  _focusNoteFromDeepLink() {
    const id = this.focusNoteIdValue
    if (!id) return
    setTimeout(() => {
      const el = this.element.querySelector(`[data-note-id="${CSS.escape(id)}"]`)
      if (!el) return
      el.scrollIntoView({ behavior: "smooth", block: "center" })
      // Inline styles so the highlight never depends on Tailwind purging
      // arbitrary-value ring utilities only referenced from JS.
      el.style.transition = "box-shadow 0.4s ease"
      el.style.borderRadius = "1rem"
      el.style.boxShadow = "0 0 0 2px #D97757, 0 0 0 6px rgba(217,119,87,0.18)"
      setTimeout(() => { el.style.boxShadow = "none" }, 2800)
    }, 200)
  }

  disconnect() {
    this._ws?.close()
    clearTimeout(this._ctxTimer)
    try { this._speech?.stop() } catch (_) {}
    this._clearTyping()
  }

  toggleQuickActions() {
    // Family viewers get the inline quick-reply chips panel; clinicians
    // get a small dropdown popover handled by quick_actions_controller
    // wrapping the + button. Only the family path lives here now.
    if (this.hasQuickActionsTarget) {
      this.quickActionsTarget.classList.toggle("hidden")
    }
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
    this._cancelRequested = false
    this._voiceTranscript = ""
    this._voiceInterim   = ""
    const mime = ["audio/webm;codecs=opus", "audio/webm", "audio/mp4", "audio/ogg;codecs=opus"]
                   .find((c) => MediaRecorder.isTypeSupported(c)) || ""
    this._mediaRecorder = mime ? new MediaRecorder(stream, { mimeType: mime }) : new MediaRecorder(stream)
    this._mediaRecorder.ondataavailable = (e) => { if (e.data && e.data.size > 0) this._audioChunks.push(e.data) }
    this._mediaRecorder.onstop = () => this._finalizeRecording()
    this._mediaRecorder.start(1000)
    // Web Speech runs in parallel so the audio note also lands a
    // text body. Browsers without Web Speech still get the audio.
    this._startVoiceTranscription()
    this._recordStartMs = Date.now()
    this._setComposerRecording(true)
    this._startRecordTimer()
  }

  _startVoiceTranscription() {
    const SR = window.SpeechRecognition || window.webkitSpeechRecognition
    if (!SR) { this._voiceSpeech = null; return }
    const r = new SR()
    r.lang           = this.langValue || "en-US"
    r.continuous     = true
    r.interimResults = true
    r.onresult = (e) => {
      let interim = ""
      let final   = this._voiceTranscript
      for (let i = e.resultIndex; i < e.results.length; i++) {
        const t = e.results[i][0].transcript
        if (e.results[i].isFinal) { final += t } else { interim += t }
      }
      this._voiceTranscript = final
      this._voiceInterim    = interim
    }
    r.onend = () => {
      // Continuous mode self-ends on long silences; restart unless
      // we explicitly stopped recording.
      if (this._mediaRecorder && this._mediaRecorder.state === "recording") {
        try { r.start() } catch (_) {}
      }
    }
    try { r.start() } catch (_) {}
    this._voiceSpeech = r
  }

  _stopRecording() {
    if (this._mediaRecorder) {
      try { this._mediaRecorder.stop() } catch (_) {}
    }
    if (this._voiceSpeech) {
      try { this._voiceSpeech.stop() } catch (_) {}
    }
    this._stopRecordTimer()
  }

  // Discard the in-progress recording without sending. Wired to the
  // trash button in the 'Living Wave' recording bar.
  cancelRecord() {
    if (!this._mediaRecorder || this._mediaRecorder.state === "inactive") return
    this._cancelRequested = true
    this._stopRecording()
  }

  // Living Wave bar's trash button: routes to the right cancel based
  // on which mode is active (audio recording vs voice dictation).
  cancelComposing() {
    if (this._mediaRecorder && this._mediaRecorder.state !== "inactive") {
      this.cancelRecord()
    } else if (this._dictateMode) {
      this._userStopped = true
      this._dictateMode = false
      try { this._speech?.stop() } catch (_) {}
      // Restore form view; clear any partial dictation from the input
      // so the user starts fresh (the trash icon means 'discard').
      if (this.hasInputTarget) this.inputTarget.value = ""
      this.refreshPlaceholderOverlay()
      this._setComposerRecording(false)
      this._stopRecordTimer()
    }
  }

  // Living Wave bar's send button: routes to the right finish based
  // on which mode is active.
  stopAndSend() {
    if (this._mediaRecorder && this._mediaRecorder.state !== "inactive") {
      // Audio recording path: stop the recorder; the existing onstop
      // handler finalizes + posts.
      this.toggleRecord()
    } else if (this._dictateMode) {
      // Dictate path: stop speech, ship the transcript already in
      // the input field as a typed message.
      this.toggleMic()
    }
  }

  _finalizeRecording() {
    const type = this._mediaRecorder.mimeType || "audio/webm"
    const ext  = type.includes("ogg") ? "ogg" : (type.includes("mp4") ? "m4a" : "webm")
    const blob = new Blob(this._audioChunks, { type })
    const cancelled = this._cancelRequested
    this._cancelRequested = false
    if (this._mediaStream) {
      this._mediaStream.getTracks().forEach((t) => { try { t.stop() } catch (_) {} })
      this._mediaStream = null
    }
    this._setComposerRecording(false)
    if (cancelled) {
      this._pendingAudio = null
      this._voiceTranscript = ""
      this._voiceInterim   = ""
      return
    }
    this._pendingAudio = new File([blob], `voice-${Date.now()}.${ext}`, { type })
    // Inject the Web Speech transcript into the input so the message
    // body carries the spoken text alongside the audio attachment.
    // send() reads this.inputTarget.value as the body.
    if (this.hasInputTarget) {
      const transcript = (this._voiceTranscript + " " + this._voiceInterim).trim()
      if (transcript.length) this.inputTarget.value = transcript
    }
    this._voiceTranscript = ""
    this._voiceInterim   = ""
    // Auto-send the voice note immediately — same UX as iMessage / WhatsApp.
    // Cancel button gives the user a non-send exit.
    this.send(new Event("submit", { cancelable: true }))
  }

  _setComposerRecording(recording) {
    if (this.hasComposerTarget) {
      this.composerTarget.dataset.recording = recording ? "true" : "false"
    }
  }

  _startRecordTimer() {
    if (this.hasRecordTimerTarget) this.recordTimerTarget.textContent = "0:00"
    this._recordTimerInterval = setInterval(() => {
      if (!this.hasRecordTimerTarget) return
      const sec = Math.floor((Date.now() - this._recordStartMs) / 1000)
      this.recordTimerTarget.textContent = `${Math.floor(sec / 60)}:${String(sec % 60).padStart(2, "0")}`
    }, 250)
  }

  _stopRecordTimer() {
    if (this._recordTimerInterval) clearInterval(this._recordTimerInterval)
    this._recordTimerInterval = null
  }

  _paintRecord(state) {
    if (!this.hasRecordButtonTarget) return
    const btn  = this.recordButtonTarget
    const icon = btn.querySelector("i")
    btn.dataset.state = state
    if (state === "recording") {
      btn.classList.add("bg-[#C1403A]", "text-white", "animate-pulse")
      btn.classList.remove("bg-[#FBF9F5]", "text-[#C1403A]")
      if (icon) { icon.classList.remove("ri-voiceprint-line"); icon.classList.add("ri-stop-circle-line") }
    } else {
      btn.classList.remove("bg-[#C1403A]", "text-white", "animate-pulse")
      btn.classList.add("bg-[#FBF9F5]", "text-[#C1403A]")
      if (icon) { icon.classList.remove("ri-stop-circle-line"); icon.classList.add("ri-voiceprint-line") }
    }
  }

  // Hide the styled placeholder overlay as soon as the user types, show
  // it again when the input is empty. Bound to the input's `input` event.
  refreshPlaceholderOverlay() {
    if (!this.hasPlaceholderOverlayTarget || !this.hasInputTarget) return
    this.placeholderOverlayTarget.classList.toggle("hidden", this.inputTarget.value.length > 0)
  }

  // No more audience toggle. HosAlivio classifies every clinician
  // message server-side and decides clinician_only vs family-visible.
  // Old toggleAudience() / _isInternal() helpers removed.

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
      // Tapping the Living Wave's send button while in dictate mode
      // stops the speech recognition AND submits the form so the
      // transcript ships as a normal text message.
      this._userStopped = true
      this._dictateMode = false
      try { this._speech.stop() } catch (_) {}
      this._setComposerRecording(false)
      this._stopRecordTimer()
      // Defer the send so the speech onend handler has a chance to
      // flush any final transcript into the input first.
      setTimeout(() => this.send(new Event("submit", { cancelable: true })), 60)
    } else {
      this._micStartText = this.inputTarget.value
      this._userStopped  = false
      this._dictateMode  = true
      try { this._speech.start() } catch (_) { /* already running */ }
      // Show the Living Wave bar with cancel + wave + timer + send.
      // Same visual the voiceprint record flow uses — the user gets
      // a single mental model and the bar's send button below routes
      // back into toggleMic to stop + ship.
      this._setComposerRecording(true)
      this._recordStartMs = Date.now()
      this._startRecordTimer()
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
    // Swap the static mic icon for the inline wave bars while
    // listening, so the dictate flow shows the same energy animation
    // as the voiceprint record flow. Input stays visible underneath
    // so Pascal sees the transcript filling in as he speaks.
    if (this.hasMicIconTarget && this.hasMicWaveTarget) {
      if (on) {
        this.micIconTarget.classList.add("hidden")
        this.micWaveTarget.classList.remove("hidden")
        this.micWaveTarget.classList.add("inline-flex")
      } else {
        this.micIconTarget.classList.remove("hidden")
        this.micWaveTarget.classList.add("hidden")
        this.micWaveTarget.classList.remove("inline-flex")
      }
    }
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

    // Family viewers post to /family_messages (HosAlivio-triaged); clinicians
    // post to /clinician_messages (saved as themselves with their real name).
    const isFamily = document.body.dataset.viewerFamily === "true"
    const url      = isFamily ? "/api/v1/family_messages" : "/api/v1/clinician_messages"

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
    // Schedule the "HosAlivio is thinking" indicator for both family
     // (waiting for a clinician to read + reply) and clinicians (waiting
     // for HosAlivio to answer Q&A or post a dispatch ack). The indicator
     // is harmless when no reply lands within 30s; the fallback copy
     // softens it to "we'll reply as soon as we can".
     this._scheduleTyping(800)

    let resp
    if (audio) {
      // Multipart: voice note (with optional text caption).
      const fd = new FormData()
      fd.append("patient_id", this.patientIdValue)
      fd.append("text",       text)
      fd.append("urgency",    sentUrgency)
      fd.append("source",     "voice")
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
          source:     wasVoice ? "voice" : "text"
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
    const wrap = document.createElement("div")
    wrap.className = "max-w-2xl mx-auto opacity-0 transition-opacity duration-300"
    wrap.innerHTML = `
      <div class="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-[#EFECE6] border border-[#EFECE6] ring-1 ring-dashed ring-[#B9B4AB]">
        <div class="w-7 h-7 rounded-full bg-[#D97757] flex items-center justify-center text-white flex-shrink-0">
          <i class="ri-heart-pulse-line text-[14px]"></i>
        </div>
        <span class="text-[10px] font-bold uppercase tracking-widest text-[#6B665F]">HosAlivio</span>
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

    // Fallback: if no reply lands within 90s, swap the dots for a calm
    // message. Bumped from 30s because the dev queue adapter is :inline
    // and Claude can occasionally take 20-40s under load; 30s was
    // creating false negatives where the reply lands at second 35.
    this._typingFallback = setTimeout(() => this._showTypingFallback(), 90000)
  }

  _showTypingFallback() {
    if (!this._typingEl) return
    this._typingEl.innerHTML = `
      <div class="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-[#EFECE6] border border-[#EFECE6] ring-1 ring-dashed ring-[#B9B4AB]">
        <div class="w-7 h-7 rounded-full bg-[#D97757] flex items-center justify-center text-white flex-shrink-0">
          <i class="ri-heart-pulse-line text-[14px]"></i>
        </div>
        <span class="text-[12px] text-[#3A3936]">Still working on it, this is taking longer than usual...</span>
      </div>
    `

    // Belt-and-suspenders: if the fallback fired, the WebSocket may have
    // missed the broadcast (background tab, transient disconnect). Try to
    // reload the chat once so the user doesn't have to manually refresh.
    if (!this._fallbackReloaded) {
      this._fallbackReloaded = true
      setTimeout(() => {
        if (this._typingEl) window.location.reload()
      }, 4000)
    }
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
      ${n.audio_url ? `<audio src="${n.audio_url}" controls class="w-full h-9 mt-2"></audio>` : ""}
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
    bubble.querySelector("p").innerHTML = this._mentionHTML(n.body)
    this._placeBubble(bubble, n)
    requestAnimationFrame(() => { bubble.style.opacity = "1" })
    this._scrollToBottom()
  }

  _appendHosalivioOffer(n) {
    const time = new Date(n.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", timeZone: this.timezoneValue })
    // Body is "[HOSALIVIO_OFFER]<base64 payload>\n<preview>"; show only the preview.
    const raw = String(n.body || "")
    const text = raw.startsWith("[HOSALIVIO_OFFER]") ? raw.replace(/^[^\n]*\n/, "") : raw

    const wrap = document.createElement("div")
    wrap.className = "max-w-2xl flex items-start gap-3 px-3 py-2 rounded-2xl bg-[#FBF9F5] border border-dashed border-[#D9B8A6] opacity-0 transition-opacity duration-300"
    wrap.title = "HosAlivio drafted this message. It has not been sent yet."
    wrap.setAttribute("data-relay-offer", "")
    wrap.setAttribute("data-relay-message", this._decodeOfferMessage(raw))
    wrap.innerHTML = `
      <div class="w-7 h-7 rounded-full bg-[#D97757] flex items-center justify-center text-white flex-shrink-0">
        <i class="ri-mail-send-line text-[14px]"></i>
      </div>
      <div class="min-w-0 flex-1">
        <div class="text-[10px] uppercase tracking-[0.18em] text-[#6B665F] font-bold">HosAlivio · draft, not sent</div>
        <div data-relay-preview class="text-[13px] text-[#1D1C1A] mt-0.5 whitespace-pre-wrap break-words [overflow-wrap:anywhere]"></div>
        <textarea data-relay-edit rows="3" maxlength="4000"
                  class="hidden w-full mt-1.5 text-[13px] rounded-lg border border-[#D9B8A6] bg-white px-2 py-1.5 text-[#1D1C1A] focus:outline-none focus:ring-1 focus:ring-[#D97757]"></textarea>
        <div class="mt-2 flex items-center gap-2" data-relay-actions>
          <button type="button" data-action="click->patient-chat#confirmRelay" data-decision="yes"
                  class="inline-flex items-center gap-1 rounded-full bg-[#D97757] hover:bg-[#c46a4b] text-white px-3 py-1 text-[12px] font-medium">
            <i class="ri-send-plane-fill text-[12px]"></i> Send
          </button>
          <button type="button" data-action="click->patient-chat#editRelay" data-relay-edit-btn
                  class="inline-flex items-center gap-1 rounded-full bg-white border border-[#E4E0D8] hover:bg-[#F2EEE7] text-[#6B665F] px-3 py-1 text-[12px] font-medium">
            <i class="ri-pencil-line text-[12px]"></i> Edit
          </button>
          <button type="button" data-action="click->patient-chat#confirmRelay" data-decision="cancel"
                  class="inline-flex items-center gap-1 rounded-full bg-white border border-[#E4E0D8] hover:bg-[#F2EEE7] text-[#6B665F] px-3 py-1 text-[12px] font-medium">
            Cancel
          </button>
        </div>
      </div>
      <div class="text-[10px] text-[#6B665F] font-mono flex-shrink-0 mt-0.5">${time}</div>
    `
    wrap.querySelector("[data-relay-preview]").textContent = text
    this.feedTarget.appendChild(wrap)
    requestAnimationFrame(() => { wrap.style.opacity = "1" })
    this._scrollToBottom()
  }

  // Decode the raw message out of a "[HOSALIVIO_OFFER]<base64 json>\n…" body
  // so the Edit textarea pre-fills with the exact draft (not the quoted
  // preview). UTF-8-safe. Returns "" if anything is off.
  _decodeOfferMessage(raw) {
    if (!String(raw).startsWith("[HOSALIVIO_OFFER]")) return ""
    try {
      const b64 = raw.slice("[HOSALIVIO_OFFER]".length, raw.indexOf("\n"))
      const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
      return JSON.parse(new TextDecoder().decode(bytes)).message || ""
    } catch (_) { return "" }
  }

  // Edit button on a relay offer: swap the preview for a pre-filled textarea.
  // Send then picks up the textarea's value (see confirmRelay).
  editRelay(event) {
    const pill = event.currentTarget.closest("[data-relay-offer]")
    if (!pill) return
    const preview  = pill.querySelector("[data-relay-preview]")
    const textarea = pill.querySelector("[data-relay-edit]")
    if (!textarea) return
    textarea.value = pill.getAttribute("data-relay-message") || (preview ? preview.textContent : "")
    if (preview) preview.classList.add("hidden")
    textarea.classList.remove("hidden")
    textarea.focus()
    event.currentTarget.classList.add("hidden")
  }

  // Click handler for the Send/Cancel buttons on a relay preview. Hits the
  // silent confirm endpoint (NOT the chat-message path) so confirming
  // doesn't drop a "yes" bubble into the thread. The backend acts on the
  // patient's pending offer directly and broadcasts the "Sent"/"won't send"
  // ack via Cable. Buttons disable on click to prevent a double-send.
  async confirmRelay(event) {
    const btn      = event.currentTarget
    const decision = btn.dataset.decision === "cancel" ? "cancel" : "yes"
    const pill     = btn.closest("[data-relay-offer]")
    // If the Edit textarea is open, Send delivers that edited text instead.
    let edited = null
    if (decision === "yes" && pill) {
      const ta = pill.querySelector("[data-relay-edit]")
      if (ta && !ta.classList.contains("hidden")) edited = ta.value.trim()
    }
    if (pill) {
      pill.querySelectorAll("button[data-decision]").forEach((b) => {
        b.disabled = true
        b.classList.add("opacity-50", "pointer-events-none")
      })
      const actions = pill.querySelector("[data-relay-actions]")
      if (actions) actions.innerHTML =
        `<span class="text-[11px] text-[#9A938A] italic">${decision === "yes" ? "Sending…" : "Cancelling…"}</span>`
    }

    const csrfMeta = document.querySelector("meta[name='csrf-token']")
    const csrf     = csrfMeta ? csrfMeta.content : ""
    if (decision === "yes") this._scheduleTyping(800)
    try {
      const resp = await fetch("/api/v1/clinician_messages/confirm_relay", {
        method:  "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrf },
        body:    JSON.stringify({ patient_id: this.patientIdValue, decision, ...(edited ? { message: edited } : {}) })
      })
      if (!resp.ok) { console.error("relay confirm failed:", resp.status, await resp.text()); this._clearTyping() }
    } catch (e) {
      console.error("relay confirm error:", e); this._clearTyping()
    }
  }

  _appendHosalivioAck(n) {
    const time = new Date(n.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", timeZone: this.timezoneValue })
    const text = String(n.body || "").replace(/^\[HOSALIVIO_ACK\]\s*/, "")

    const wrap = document.createElement("div")
    wrap.className = "max-w-2xl flex items-start gap-3 px-3 py-2 rounded-2xl bg-[#FBF9F5] border border-[#EFECE6] opacity-0 transition-opacity duration-300"
    wrap.title = "HosAlivio reply"
    wrap.innerHTML = `
      <div class="w-7 h-7 rounded-full bg-[#D97757] flex items-center justify-center text-white flex-shrink-0">
        <i class="ri-heart-pulse-line text-[14px]"></i>
      </div>
      <div class="min-w-0 flex-1">
        <div class="text-[10px] uppercase tracking-[0.18em] text-[#6B665F] font-bold">HosAlivio</div>
        <div data-role="ack" class="text-[13px] text-[#1D1C1A] mt-0.5 whitespace-pre-wrap"></div>
      </div>
      <div class="text-[10px] text-[#6B665F] font-mono flex-shrink-0 mt-0.5">${time}</div>
    `
    wrap.querySelector('[data-role="ack"]').textContent = text
    this.feedTarget.appendChild(wrap)
    requestAnimationFrame(() => { wrap.style.opacity = "1" })
    this._scrollToBottom()
  }

  _appendGuardrailBlock(n) {
    const time = new Date(n.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", timeZone: this.timezoneValue })
    const reason = String(n.body || "").replace(/^\[GUARDRAIL_BLOCKED\]\s*/, "")

    const wrap = document.createElement("div")
    wrap.className = "max-w-3xl flex items-center gap-3 px-4 py-2.5 rounded-xl border border-[#C1403A] bg-[#FFF3EC] opacity-0 transition-opacity duration-300"
    wrap.title = "HosAlivio guardrail blocked this action. Audit-logged."
    wrap.innerHTML = `
      <i class="ri-shield-cross-line text-[#C1403A] text-[18px] flex-shrink-0"></i>
      <div class="min-w-0 flex-1">
        <div class="text-[10px] uppercase tracking-[0.18em] text-[#C1403A] font-bold">
          Guardrail blocked
        </div>
        <div data-role="reason" class="text-[13px] text-[#1D1C1A] mt-0.5"></div>
      </div>
      <div class="text-[10px] text-[#6B665F] font-mono flex-shrink-0">${time}</div>
    `
    wrap.querySelector('[data-role="reason"]').textContent = reason
    this.feedTarget.appendChild(wrap)
    requestAnimationFrame(() => { wrap.style.opacity = "1" })
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
    const roleLabel = String(n.author_role || "").replace(/_/g, " ").toUpperCase()
    const urgencyPill = n.urgency === "crisis"
      ? `<span class="inline-flex items-center gap-1 text-[9px] font-bold text-[#C1403A] uppercase tracking-wider"><span class="w-1.5 h-1.5 rounded-full bg-[#C1403A] animate-pulse"></span>crisis</span>`
      : n.urgency === "urgent"
      ? `<span class="inline-flex items-center gap-1 text-[9px] font-bold text-[#D97757] uppercase tracking-wider"><span class="w-1.5 h-1.5 rounded-full bg-[#D97757]"></span>urgent</span>`
      : ""

    // Pick the summary label + icon based on the audit_kind classifier
    // (mirrors Note#audit_kind on the server). Also strip the redundant
    // 'Role rationale\n\n' prefix from the body when audit_kind=rationale.
    const kind = n.audit_kind || "chart"
    let label, icon, body = n.body || ""
    switch (kind) {
      case "triage":
        label = "HosAlivio · triage"
        icon  = "ri-radar-line"
        break
      case "rationale":
        label = `Why the ${roleLabel} agent acted`
        icon  = "ri-lightbulb-line"
        body  = body.replace(/^[A-Z][\w ]+ rationale\n\n/, "")
        break
      case "chart":
      default:
        label = `${roleLabel} chart entry`
        icon  = "ri-file-text-line"
    }

    const det = document.createElement("details")
    det.className = "group max-w-3xl opacity-0 transition-opacity duration-300"
    det.innerHTML = `
      <summary class="cursor-pointer list-none flex items-center gap-2 py-1.5 px-3 text-[11px] text-[#6B665F] hover:bg-[#FBF9F5] rounded-md transition [&::-webkit-details-marker]:hidden">
        <i class="ri-arrow-right-s-line group-open:rotate-90 transition-transform"></i>
        <i class="${icon} text-[#B9B4AB]"></i>
        <span class="uppercase tracking-[0.18em] text-[9px] font-bold">${label}</span>
        ${urgencyPill}
        <span class="text-[10px] text-[#B9B4AB] font-mono ml-auto">${time}</span>
      </summary>
      <div class="ml-6 mt-1 mb-2 py-2 px-3 bg-[#FBF9F5] border-l-2 border-[#D9D5CD] rounded-r-md">
        <div data-role="body" class="text-[12px] text-[#3A3936] leading-relaxed whitespace-pre-wrap break-words [overflow-wrap:anywhere]"></div>
      </div>
    `
    const bodyEl = det.querySelector('[data-role="body"]')
    bodyEl.innerHTML = this._renderAuditBodyHTML(body)
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
      if (!payload) return
      // Clinical facts (vitals, visits, meds, eval, crises) changed — the
      // server only nudges us; re-fetch the right-rail so each viewer gets
      // their own role-scoped render. No PHI rides the socket.
      if (payload.kind === "context_changed") { this._refreshContext(); return }
      if (payload.kind !== "note") return
      this._appendNote(payload)
    }
  }

  // Debounced re-fetch of the clinical-context right-rail. A burst of
  // changes (e.g. a visit finish that also logs vitals + meds) collapses
  // into one request. On failure we keep the stale rail rather than blank it.
  _refreshContext() {
    clearTimeout(this._ctxTimer)
    this._ctxTimer = setTimeout(async () => {
      const el = document.getElementById("patient-clinical-context")
      if (!el) return
      try {
        const resp = await fetch(`/patients/${this.patientIdValue}/clinical_context`, {
          headers: { "Accept": "text/html", "X-Requested-With": "XMLHttpRequest" },
          credentials: "same-origin"
        })
        if (!resp.ok) return
        el.innerHTML = await resp.text()
      } catch (_) { /* keep the existing rail on network error */ }
    }, 250)
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
    //   1. guardrail block ([GUARDRAIL_BLOCKED]) — red pill
    //   2. action banner ([ACTION:...] marker) — green success bar
    //   3. HosAlivio ack ([HOSALIVIO_ACK]) — bot-avatar pill
    //   4. IDG huddle bubble (real human author) — dashed muted bubble
    //   5. audit rationale (no human author) — collapsed audit row
    if (n.clinician_only) {
      // Clear the "HosAlivio is thinking" dots when any system /
      // HosAlivio message lands. Without this, the typing indicator
      // would stick around forever after a Q&A reply or dispatch ack.
      if (n.audit_kind === "hosalivio_ack" || n.audit_kind === "hosalivio_offer" || n.audit_kind === "guardrail" || n.action_payload) {
        this._clearTyping()
      }
      if (n.audit_kind === "guardrail") {
        this._appendGuardrailBlock(n)
      } else if (n.action_payload) {
        this._appendActionBanner(n)
      } else if (n.audit_kind === "hosalivio_offer") {
        this._appendHosalivioOffer(n)
      } else if (n.audit_kind === "hosalivio_ack") {
        this._appendHosalivioAck(n)
      } else if (n.author_user_id) {
        this._appendHuddleBubble(n)
      } else {
        this._appendAuditLog(n)
      }
      return
    }

    // Clear the typing indicator only when the incoming note is
    // from SOMEONE ELSE (a reply we were waiting on). The viewer's
    // own message echoes back via Cable — we must not treat that
    // echo as the awaited reply, otherwise the indicator vanishes
    // before HosAlivio's actual response lands and the user sees
    // nothing happening between send and reply.
    const viewerId = document.body.dataset.viewerUserId || ""
    const isOwnEcho = viewerId && n.author_user_id && String(n.author_user_id) === String(viewerId)
    if (!isOwnEcho && n.author_role !== "family") this._clearTyping()

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
    // to the backend-supplied label ("HosAlivio") only for AI notes.
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
           <img src="${document.body.dataset.hosalivioBotSrc || '/assets/hosalivio_assistant.png'}" class="w-full h-full object-cover object-top scale-125 origin-top" alt="HosAlivio">
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
      bodyEl.innerHTML = this._mentionHTML(n.body)
    } else {
      bodyEl.remove()
    }
    this._placeBubble(bubble, n)
    requestAnimationFrame(() => { bubble.style.opacity = "1" })
    this._scrollToBottom()
  }

  // ── Threading: placement, nesting, reply composer ────────────────────

  // A reply nests under its parent's thread container; a root is wrapped so
  // replies can nest under it later. Parent not in the DOM (e.g. older than
  // the 50-note window) → fall back to a flat append.
  _placeBubble(bubble, n) {
    if (n.parent_note_id) {
      const container = this._threadContainerFor(n.parent_note_id)
      if (container) { this._nestReply(container, bubble, n.parent_note_id); return }
      this.feedTarget.appendChild(bubble)
      return
    }
    const wrap = document.createElement("div")
    if (n.note_id) wrap.setAttribute("data-note-id", n.note_id)
    wrap.appendChild(bubble)
    // Only conversational notes get a Reply affordance — mirrors the server.
    if (n.note_id && this._conversational(n)) wrap.appendChild(this._buildThreadBlock(n.note_id))
    this.feedTarget.appendChild(wrap)
  }

  _conversational(n) {
    if (n.action_payload) return false
    const NON_CONV = ["action", "guardrail", "hosalivio_ack", "triage", "rationale"]
    return !(n.audit_kind && NON_CONV.includes(n.audit_kind))
  }

  _threadContainerFor(parentId) {
    return this.feedTarget.querySelector(`[data-thread-replies-for="${CSS.escape(String(parentId))}"]`)
  }

  _nestReply(container, bubble, parentId) {
    container.appendChild(bubble)
    container.classList.remove("hidden")
    const header = this.feedTarget.querySelector(`[data-thread-header-for="${CSS.escape(String(parentId))}"]`)
    if (header) header.classList.remove("hidden")
    const count = container.children.length
    const label = this.feedTarget.querySelector(`[data-thread-label-for="${CSS.escape(String(parentId))}"]`)
    if (label) label.textContent = `${count} ${count === 1 ? "reply" : "replies"}`
  }

  // Mirrors the server-rendered thread block in show.html.erb so live root
  // notes get the same reply button + collapsible replies container.
  _buildThreadBlock(noteId) {
    const block = document.createElement("div")
    block.className = "ml-7 md:ml-12 mt-1"
    block.innerHTML = `
      <button type="button" data-action="click->patient-chat#toggleThread" data-thread-header-for="${noteId}"
              class="hidden inline-flex items-center gap-1 text-[11px] text-[#6B665F] hover:text-[#1D1C1A] font-medium">
        <i class="ri-corner-down-right-line"></i>
        <span data-thread-label-for="${noteId}">0 replies</span>
        <i class="ri-arrow-up-s-line transition-transform" data-thread-chevron></i>
      </button>
      <div data-thread-replies-for="${noteId}" class="pl-3 border-l-2 border-[#EFECE6] space-y-2 mt-1 hidden"></div>
      <button type="button" data-action="click->patient-chat#openReply" data-note-id="${noteId}"
              class="mt-1 inline-flex items-center gap-1 text-[11px] text-[#D97757] hover:underline font-medium">
        <i class="ri-reply-line"></i> Reply
      </button>
    `
    return block
  }

  // Collapse / expand a thread.
  toggleThread(e) {
    const noteId = e.currentTarget.dataset.threadHeaderFor
    const container = this._threadContainerFor(noteId)
    if (!container) return
    const hidden = container.classList.toggle("hidden")
    const chevron = e.currentTarget.querySelector("[data-thread-chevron]")
    if (chevron) chevron.classList.toggle("rotate-180", hidden)
  }

  // Reveal (or focus) an inline reply composer under a note. Supports a typed
  // reply or a voice reply (mic → record → Send posts multipart audio).
  openReply(e) {
    const noteId = e.currentTarget.dataset.noteId
    const wrap = this.feedTarget.querySelector(`[data-note-id="${CSS.escape(String(noteId))}"]`)
    if (!wrap) return
    const existing = wrap.querySelector(`[data-reply-composer-for="${CSS.escape(String(noteId))}"]`)
    if (existing) { existing.querySelector("input").focus(); return }

    const composer = document.createElement("form")
    composer.setAttribute("data-reply-composer-for", noteId)
    composer.className = "ml-7 md:ml-12 mt-1 flex items-center gap-2"
    composer.innerHTML = `
      <button type="button" data-reply-mic title="Record a voice reply"
              class="flex-shrink-0 w-8 h-8 rounded-full border border-[#D9D5CD] bg-white text-[#6B665F] hover:bg-[#FBF9F5] flex items-center justify-center">
        <i class="ri-mic-line"></i>
      </button>
      <input type="text" placeholder="Reply…" maxlength="2000"
             class="flex-1 min-w-0 rounded-full border border-[#D9D5CD] bg-white px-3 py-1.5 text-[13px] focus:outline-none focus:ring-1 focus:ring-[#D97757]" />
      <button type="submit" class="inline-flex items-center gap-1 rounded-full bg-[#D97757] hover:bg-[#c46a4b] text-white px-3 py-1.5 text-[12px] font-medium">
        <i class="ri-send-plane-2-line"></i> Send
      </button>
      <button type="button" data-reply-cancel class="text-[11px] text-[#6B665F] hover:text-[#1D1C1A]">Cancel</button>
    `
    wrap.appendChild(composer)
    const input = composer.querySelector("input")
    input.focus()
    composer.addEventListener("submit", (ev) => { ev.preventDefault(); this._submitReply(noteId, composer) })
    composer.querySelector("[data-reply-cancel]").addEventListener("click", () => { this._stopReplyRecording(composer); composer.remove() })
    composer.querySelector("[data-reply-mic]").addEventListener("click", () => this._toggleReplyRecording(composer))
  }

  // Toggle voice recording for a reply composer. Self-contained (its own
  // MediaRecorder + stream) so it never collides with the main composer mic.
  async _toggleReplyRecording(composer) {
    const mic = composer.querySelector("[data-reply-mic]")
    if (composer._recorder && composer._recorder.state === "recording") {
      composer._recorder.stop()
      return
    }
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      const rec    = new MediaRecorder(stream)
      const chunks = []
      rec.ondataavailable = (ev) => { if (ev.data && ev.data.size) chunks.push(ev.data) }
      rec.onstop = () => {
        composer._audioBlob = new Blob(chunks, { type: rec.mimeType || "audio/webm" })
        stream.getTracks().forEach((t) => t.stop())
        mic.classList.remove("bg-[#C1403A]", "text-white", "animate-pulse")
        mic.classList.add("bg-white", "text-[#6B665F]")
        mic.querySelector("i").className = "ri-check-line"
        mic.title = "Voice reply ready — tap Send"
      }
      composer._recorder = rec
      rec.start()
      mic.classList.remove("bg-white", "text-[#6B665F]")
      mic.classList.add("bg-[#C1403A]", "text-white", "animate-pulse")
      mic.querySelector("i").className = "ri-stop-fill"
      mic.title = "Stop recording"
    } catch (err) {
      console.error("reply mic error:", err)
    }
  }

  _stopReplyRecording(composer) {
    if (composer._recorder && composer._recorder.state === "recording") composer._recorder.stop()
  }

  // POST the reply with parent_note_id (multipart when a voice clip is
  // attached). The saved note Cable-echoes back and _placeBubble nests it,
  // same as a normal message renders via its echo.
  async _submitReply(noteId, composer) {
    const input = composer.querySelector("input")
    const text  = input.value.trim()
    const blob  = composer._audioBlob
    if (!text && !blob) return
    const isFamily = document.body.dataset.viewerFamily === "true"
    const url      = isFamily ? "/api/v1/family_messages" : "/api/v1/clinician_messages"
    const csrfMeta = document.querySelector("meta[name='csrf-token']")
    const csrf     = csrfMeta ? csrfMeta.content : ""
    composer.remove()
    try {
      let resp
      if (blob) {
        const fd = new FormData()
        fd.append("patient_id",     this.patientIdValue)
        fd.append("text",           text)
        fd.append("parent_note_id", noteId)
        fd.append("source",         "voice")
        fd.append("audio",          blob, "reply.webm")
        resp = await fetch(url, { method: "POST", headers: { "Accept": "application/json", "X-CSRF-Token": csrf }, body: fd })
      } else {
        resp = await fetch(url, {
          method:  "POST",
          headers: { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrf },
          body:    JSON.stringify({ patient_id: this.patientIdValue, text, parent_note_id: noteId, source: "text" })
        })
      }
      if (!resp.ok) console.error("reply failed:", resp.status, await resp.text())
    } catch (err) {
      console.error("reply error:", err)
    }
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
