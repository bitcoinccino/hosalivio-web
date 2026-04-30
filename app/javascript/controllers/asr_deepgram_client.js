// Thin streaming client for Deepgram Realtime. Opens a WebSocket
// to wss://api.deepgram.com/v1/listen with the short-lived API key
// the Rails AsrSessionsController issued, pipes MediaRecorder
// chunks straight in, and emits transcript events as they arrive.
//
// Diarization output: each word in a Deepgram transcript carries
// a `speaker` integer (0, 1, 2 ...) representing voice clusters.
// We map those to display labels per visit (first speaker seen
// becomes "Speaker 1" etc.) and let the recording page show that
// in the live transcript without the manual Patient said... / RN
// said... pills (which stay as a fallback when this client is
// unavailable, e.g. Creole patients on Web Speech).

export default class AsrDeepgramClient {
  constructor({ websocketUrl, token, roster, onTranscript, onError, onClose }) {
    this.websocketUrl = websocketUrl
    this.token        = token
    this.onTranscript = onTranscript || (() => {})
    this.onError      = onError      || (() => {})
    this.onClose      = onClose      || (() => {})
    this.ws           = null
    this.recorder     = null
    this.stream       = null
    this._open        = false
    this._finalText   = ""
    this._lastSpeaker = null
    // Speaker label mapping is built lazily as new speaker indices
    // appear. Each new index claims the next slot in the roster
    // (typically [RN, Patient, Family member 1, ...]). Past the end
    // of the roster, falls back to "Speaker N" so unknown voices
    // still get distinguishable tags. Mapping persists for the
    // session so once Speaker 0 is named "Pascal", every chunk that
    // returns index 0 stays "Pascal".
    this._roster        = Array.isArray(roster) && roster.length > 0
                            ? roster
                            : []
    this._speakerLabels = new Map()
  }

  async start(stream) {
    this.stream = stream
    this.ws     = new WebSocket(this.websocketUrl, ["token", this.token])
    this.ws.binaryType = "arraybuffer"

    this.ws.onopen = () => {
      this._open = true
      this._initRecorder(stream)
    }
    this.ws.onmessage = (evt) => this._handleMessage(evt)
    this.ws.onerror   = (err) => this.onError(err)
    this.ws.onclose   = (evt) => {
      this._open = false
      try { this.recorder?.stop() } catch (_) {}
      this.onClose(evt)
    }
  }

  stop() {
    try { this.recorder?.stop() } catch (_) {}
    if (this._open && this.ws?.readyState === WebSocket.OPEN) {
      // Send Deepgram's "close stream" signal so it returns final results.
      try { this.ws.send(JSON.stringify({ type: "CloseStream" })) } catch (_) {}
    }
    setTimeout(() => { try { this.ws?.close() } catch (_) {} }, 250)
  }

  _initRecorder(stream) {
    const mime = ["audio/webm;codecs=opus", "audio/webm", "audio/ogg;codecs=opus"]
                   .find((c) => MediaRecorder.isTypeSupported(c)) || ""
    this.recorder = mime ? new MediaRecorder(stream, { mimeType: mime })
                         : new MediaRecorder(stream)
    this.recorder.ondataavailable = (e) => {
      if (e.data && e.data.size > 0 && this._open && this.ws.readyState === WebSocket.OPEN) {
        // Ship the chunk straight through. Deepgram auto-detects
        // the WebM/Opus container from the headers in the first
        // chunk; subsequent chunks are appended to the same stream.
        this.ws.send(e.data)
      }
    }
    // 250ms chunks give a smooth interim-result cadence.
    this.recorder.start(250)
  }

  _handleMessage(evt) {
    let parsed
    try { parsed = JSON.parse(evt.data) } catch (_e) { return }
    if (parsed.type !== "Results") return
    const alt = parsed.channel?.alternatives?.[0]
    if (!alt) return

    const transcript = alt.transcript || ""
    const isFinal    = parsed.is_final === true
    const speechFinal = parsed.speech_final === true
    const words      = alt.words || []

    if (transcript.length === 0 && !isFinal) return

    // Build a tagged version of the transcript that injects [Speaker N]
    // markers wherever the speaker index changes. This mirrors the
    // manual [Patient:] / [RN:] convention the extractor already
    // understands; downstream code doesn't need to learn a new format.
    let tagged = transcript
    if (words.length > 0) {
      tagged = ""
      let curSpeaker = null
      for (const w of words) {
        const sp = (typeof w.speaker === "number") ? w.speaker : null
        if (sp !== null && sp !== curSpeaker) {
          if (tagged.length > 0) tagged += "\n"
          tagged += `[${this._labelFor(sp)}:] `
          curSpeaker = sp
        }
        tagged += `${w.punctuated_word || w.word} `
      }
      tagged = tagged.trim()
    }

    if (isFinal) {
      this._finalText += (this._finalText.length > 0 ? "\n" : "") + tagged
      this.onTranscript({ kind: "final", text: this._finalText, latest: tagged, speechFinal })
    } else {
      this.onTranscript({ kind: "interim", text: this._finalText, latest: tagged, speechFinal: false })
    }
  }

  _labelFor(speakerIdx) {
    if (this._speakerLabels.has(speakerIdx)) return this._speakerLabels.get(speakerIdx)
    const slot = this._speakerLabels.size
    const fromRoster = this._roster[slot]
    const label = fromRoster || `Speaker ${slot + 1}`
    this._speakerLabels.set(speakerIdx, label)
    return label
  }

  finalText() {
    return this._finalText
  }
}
