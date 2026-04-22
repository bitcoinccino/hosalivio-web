import { Controller } from "@hotwired/stimulus"

// Connects to <main data-controller="patient-chat" data-patient-chat-patient-id-value="…">
export default class extends Controller {
  static targets = ["input", "feed", "status", "quickActions", "mic"]
  static values  = { patientId: String }

  connect() {
    this._currentUrgency = "normal"
    this._openCable()
    this._initSpeech()
    this._scrollToBottom()
  }

  disconnect() {
    this._ws?.close()
    try { this._speech?.stop() } catch (_) {}
  }

  toggleQuickActions() {
    this.quickActionsTarget.classList.toggle("hidden")
  }

  quickAction(event) {
    const btn = event.currentTarget
    this.inputTarget.value = btn.dataset.template || ""
    this._currentUrgency   = btn.dataset.urgency  || "normal"
    this.quickActionsTarget.classList.add("hidden")
    this.inputTarget.focus()
  }

  // ── Voice input (Web Speech API) ─────────────────────────────────
  toggleMic() {
    if (!this._speech) return
    if (this._listening) {
      this._speech.stop()
    } else {
      this._micStartText = this.inputTarget.value
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
    r.lang           = "en-US"
    r.interimResults = true
    r.continuous     = false

    r.onstart  = () => { this._listening = true;  this._paintMic(true)  }
    r.onend    = () => { this._listening = false; this._paintMic(false); this._usedVoice = true }
    r.onerror  = (e) => { this._listening = false; this._paintMic(false); console.warn("speech error:", e.error) }
    r.onresult = (e) => {
      let transcript = ""
      for (let i = e.resultIndex; i < e.results.length; i++) {
        transcript += e.results[i][0].transcript
      }
      this.inputTarget.value = (this._micStartText ? this._micStartText + " " : "") + transcript
    }
    this._speech = r
    if (this.hasMicTarget) {
      this.micTarget.disabled = false
      this.micTarget.title = "Hold to speak — click again to stop"
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
    const text = this.inputTarget.value.trim()
    if (!text) return

    const csrfMeta = document.querySelector("meta[name='csrf-token']")
    const csrf     = csrfMeta ? csrfMeta.content : ""

    const resp = await fetch("/api/v1/family_messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept":       "application/json",
        "X-CSRF-Token": csrf
      },
      body: JSON.stringify({
        patient_id: this.patientIdValue,
        text:       text,
        urgency:    this._currentUrgency,
        source:     this._usedVoice ? "voice" : "text"
      })
    })

    if (!resp.ok) {
      const err = await resp.text()
      console.error("send failed:", resp.status, err)
      return
    }

    // Clear input — the Cable subscription will drop the bubble in the feed.
    this.inputTarget.value = ""
    this._currentUrgency   = "normal"
    this._usedVoice        = false
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
    const bubble = document.createElement("div")
    const roleLabel = this._roleLabel(n.author_role)
    const labelColor = this._labelColor(n.author_role)
    const roleIcon  = this._roleIcon(n.author_role)
    const isFamily = n.author_role === "family"
    const align = isFamily ? "ml-auto" : ""
    const bg    = isFamily ? "bg-white" : "bg-[#EFECE6]"

    const urgencyPill = n.urgency === "crisis"
      ? `<span class="text-[10px] font-bold px-2 py-0.5 rounded bg-[#C1403A] text-white tracking-wider">CRISIS</span>`
      : n.urgency === "urgent"
      ? `<span class="text-[10px] font-bold px-2 py-0.5 rounded bg-[#D97757] text-white tracking-wider">URGENT</span>`
      : ""

    bubble.className = `max-w-2xl ${align} ${bg} rounded-3xl px-6 py-5 border border-[#EFECE6] shadow-sm opacity-0 transition-opacity duration-300`
    bubble.innerHTML = `
      <div class="flex items-center justify-between mb-1">
        <div class="inline-flex items-center gap-1.5 text-[10px] uppercase tracking-[0.18em] font-bold" style="color: ${labelColor};">
          <i class="${roleIcon} text-[12px]"></i>${roleLabel}
        </div>
        ${urgencyPill}
      </div>
      <p class="font-serif text-[16px] text-[#1D1C1A] leading-relaxed whitespace-pre-wrap"></p>
      <div class="text-[10px] text-[#6B665F] mt-2 text-right font-mono">${new Date(n.created_at).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</div>
    `
    bubble.querySelector("p").textContent = n.body
    this.feedTarget.appendChild(bubble)
    requestAnimationFrame(() => { bubble.style.opacity = "1" })
    this._scrollToBottom()
  }

  _roleIcon(role) {
    return ({
      family: "ri-user-heart-line", rn: "ri-nurse-line", md: "ri-stethoscope-line",
      social_worker: "ri-team-line", chaplain: "ri-hand-heart-line",
      pharmacy: "ri-capsule-line", admissions: "ri-customer-service-2-line",
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
      pharmacy: "Pharmacy", admissions: "Front Door",
      front_door_inbound: "Front Door", system: "System"
    })[role] || (role || "").toUpperCase()
  }

  _labelColor(role) {
    return ({
      family: "#D97757", rn: "#2F6F4E", md: "#2B4A7A",
      social_worker: "#7A4A8C", chaplain: "#8C6A2F",
      pharmacy: "#5A2F7A", admissions: "#1D1C1A",
      front_door_inbound: "#1D1C1A", system: "#6B665F"
    })[role] || "#6B665F"
  }
}
