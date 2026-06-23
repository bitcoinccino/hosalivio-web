import { Controller } from "@hotwired/stimulus"

// Full-screen visit recording stage. Three things happen in parallel
// while the RN is talking:
//
//   - Web Speech API streams interim + final transcripts into the
//     visible scroll panel; the final transcript becomes Visit#narrative.
//   - MediaRecorder captures the same audio stream as a webm/mp4 Blob
//     that ships up as Visit#audio_note (ActiveStorage).
//   - AnalyserNode + canvas paints a live frequency-bar waveform so the
//     RN sees the mic is working.
//
// On Stop we PATCH /visits/:id with multipart (narrative + audio_note),
// then redirect to /visits/:id/edit so the RN can review/correct
// before tapping Finish.
//
// Speaker labels are manually available today (the "Patient said…",
// "Family said…", and clinician pill buttons inject tags into the live
// transcript). Web Speech API does not do diarization. Phase 2 is a
// one-day drop-in: on Stop, send the audio Blob to Deepgram /
// AssemblyAI / Whisper+pyannote and replace the Web Speech text with
// real diarized labels. The narrative shape stays the same, so the
// PreAdmitNarrativeExtractor and downstream consumers don't need to
// change. Cost ~$0.006–$0.015 per minute.
//
// Transcription language defaults from Patient#preferred_language
// (2-letter ISO, mapped to BCP-47 for SpeechRecognition.lang). The
// language pill on the recording stage swaps mid-visit; ticking
// "Set as patient default" PATCHes the choice back so future visits
// pick it up automatically. Phase 2's auto-detect will deprecate
// this picker but the patient-default field stays useful.

export default class extends Controller {
  static targets = ["timer", "status", "canvas", "transcript",
                    "recordButton", "recordIcon", "pauseButton", "stopButton",
                    "consentPanel", "typePickerPanel", "interviewPanel", "stage",
                    "langButton", "langFlag", "langLabel", "langMenu", "syncLangCheckbox",
                    "speakerPills", "speakerHelp", "speakerToolsButton", "soloButton",
                    "interviewSourceLabel",
                    "asrBadge", "asrDot", "asrMode",
                    "asrToast", "asrToastText"]
  static values = {
    updateUrl:        String,
    editUrl:          String,
    discardUrl:       String,
    csrf:             String,
    lang:             { type: String, default: "en-US" },
    langCode:         { type: String, default: "en" },
    needsTypePicker:  { type: Boolean, default: false },
    suggestedType:    { type: String, default: "" },
    visitType:        { type: String, default: "" },
    patientId:        { type: String, default: "" },
    defaultInterviewSource: { type: String, default: "" },
    defaultInterviewLabel:  { type: String, default: "" },
    speakerRoster:    { type: Array,  default: [] }
  }

  connect() {
    this._audioChunks   = []
    this._stream        = null
    this._recorder      = null
    this._speech        = null
    this._listening     = false
    this._userStopped   = false
    this._uploaded      = false
    this._finalText     = ""
    this._interimText   = ""
    this._timerInterval = null
    this._rafId         = null
    this._startedAtMs   = 0
    this._pausedAtMs    = 0
    this._pausedTotalMs = 0
    this._speechError   = null
    this._noSpeechTimer = null
    this._interviewSource = this.visitTypeValue === "admission" ? this.defaultInterviewSourceValue : null
    this._interviewLabel  = this.visitTypeValue === "admission" ? this.defaultInterviewLabelValue : null
    this._speakerToolsOpen = false

    // Note: a pagehide beacon used to fire here to discard the visit
    // when the RN navigated away without tapping Stop. It raced the
    // PATCH-then-redirect on Stop (the beacon hit /discard before the
    // audio_note attachment was visible to a follow-up read), causing
    // VisitsController#edit to 404 on a freshly saved visit. Removed.
    // The Cancel link's explicit POST + DashboardsController's 5-min
    // cleanup of empty in-progress visits are sufficient.
  }

  disconnect() {
    this._teardown()
  }

  // ── Top-level toggles ─────────────────────────────────────────────

  // Consent gate — shown first. After acknowledgement we either
  // reveal the visit-type picker (ad-hoc start, type unknown) or
  // jump straight to the mic stage (scheduled visit, type already
  // set when the visit was created).
  acknowledgeConsent() {
    if (this.hasConsentPanelTarget) this.consentPanelTarget.classList.add("hidden")
    if (this.needsTypePickerValue && this.hasTypePickerPanelTarget) {
