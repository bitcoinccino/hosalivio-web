class Note < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail
  include AgentAuditable

  # Body can contain clinical details from family voice/text
  encrypts :body

  enum :source,  { text: 0, voice: 1, system: 2 }, prefix: true, validate: true
  enum :urgency, { normal: 0, urgent: 1, crisis: 2 }, prefix: true, validate: true

  belongs_to :agency
  belongs_to :patient
  belongs_to :author_user, class_name: "User", optional: true

  # Optional voice recording attached to a chat message — Carlos can hold
  # the phone near Maria and capture her breathing for Pascal to hear,
  # not just describe it in words. Distinct from `body` (typed/dictated
  # text); both can be present on the same Note.
  has_one_attached :audio

  validates :author_role, presence: true
  # Body is required unless an audio recording is attached — Carlos
  # holding the phone near Maria for breath sounds doesn't need to type.
  validates :body, presence: true, unless: -> { audio.attached? }

  scope :unread,         -> { where(read_at: nil) }
  scope :recent,         -> { order(created_at: :desc) }
  scope :family_visible, -> { where(clinician_only: false) }
  scope :clinician_only_scope, -> { where(clinician_only: true) }

  # Action banners — short, human-friendly labels for "the system did X".
  # Emitted by AgentTriager when a real-world action lands (pharmacy
  # dispatched, med ordered, DME requested, etc.). Rendered as a green
  # success bar so Pascal sees the result at a glance instead of reading
  # rationale prose to figure out what happened.
  ACTION_LABELS = {
    "pharmacy_dispatched" => "Pharmacy Dispatched",
    "med_ordered"         => "Medication Ordered",
    "dme_requested"       => "DME Requested",
    "visit_scheduled"     => "Visit Scheduled",
    "noe_filed"           => "NOE Filed",
    "pre_admit_certified" => "Hospice Election Certified",
    "pre_admit_drafted"   => "Pre-Admit Eval Drafted"
  }.freeze

  ACTION_BODY_RE = /\A\[ACTION:([a-z_]+)\]\s*(.*)\z/m

  after_create_commit :broadcast_to_patient_channel

  def mark_read!(user = nil)
    update!(read_at: Time.current) if read_at.nil?
  end

  # True when no identifiable human authored this note — i.e. an AI agent
  # produced it via AgentTriager with Current.agent_id set and no user.
  # Used by the chat UI to label bubbles "HosAlivio" instead of
  # passing off automated replies as a named clinician.
  def ai_authored?
    author_user_id.blank? && source_system?
  end

  # What the chat UI should display as the speaker's name. Never show the
  # agent's internal handle (e.g. "Pascal") — that's a codebase variable,
  # not a clinician's real identity. Humans show their real full_name;
  # AI-written notes show a clearly-automated label.
  def display_author_name
    return author_user.full_name if author_user&.full_name.present?
    return "Family" if author_role == "family"
    ai_authored? ? "HosAlivio" : author_role.to_s.upcase
  end

  # Role sub-label shown in parentheses under the speaker's name.
  # For family it's their relationship to the patient ("Son of Maria");
  # for clinicians it's the clinical role ("RN", "MD"); AI is flagged.
  # Classifies a clinician_only note into a render-shape:
  #   :action     — '[ACTION:…]' marker; rendered as a green success banner
  #   :triage     — admissions intent + 'Notified:' line; rendered as a triage row
  #   :rationale  — '<Role> rationale\n\n<why>' from log_audit_note
  #   :chart      — anything else; treated as a clinical chart entry
  RATIONALE_BODY_RE = /\A[A-Z][\w ]+ rationale\n\n/.freeze
  def audit_kind
    return :action    if action_banner?
    txt = body.to_s
    return :triage    if txt.lines.any? { |l| l.start_with?("Notified:") }
    return :rationale if txt.match?(RATIONALE_BODY_RE)
    :chart
  end

  # Strip the redundant '<Role> rationale\n\n' header from a rationale
  # note so we don't render the same label twice (once in the audit
  # summary header, once at the top of the body block).
  def display_audit_body
    return body unless audit_kind == :rationale
    body.to_s.sub(RATIONALE_BODY_RE, "")
  end

  # Returns { type:, label:, detail: } when this note is an action banner,
  # nil otherwise. Body convention: "[ACTION:pharmacy_dispatched] Comfort Kit Refill".
  def action_payload
    return nil unless body.is_a?(String)
    m = body.match(ACTION_BODY_RE)
    return nil unless m
    type = m[1]
    {
      type:   type,
      label:  ACTION_LABELS[type] || type.tr("_", " ").capitalize,
      detail: m[2].to_s.strip
    }
  end

  def action_banner?
    action_payload.present?
  end

  def display_author_subtitle
    if author_role == "family"
      rel  = author_user&.relationship.to_s.strip
      name = author_user&.patient&.first_name
      return nil if rel.blank? || name.blank?
      return "#{rel.capitalize} of #{name}"
    end
    role_up = author_role.to_s.tr("_", " ").upcase
    ai_authored? ? "AI auto-reply · #{role_up}" : role_up
  end

  private

  def broadcast_to_patient_channel
    audio_url = nil
    if audio.attached?
      audio_url = Rails.application.routes.url_helpers.rails_blob_path(audio, only_path: true)
    end
    ActionCable.server.broadcast(
      "patient:#{patient_id}",
      {
        kind:              "note",
        note_id:           id,
        author_role:       author_role,
        author_user_id:    author_user_id,
        author_name:       display_author_name,
        author_subtitle:   display_author_subtitle,
        ai_authored:       ai_authored?,
        clinician_only:    clinician_only,        # JS filters family viewers
        action_payload:    action_payload,        # nil unless body is "[ACTION:...]"
        audit_kind:        clinician_only ? audit_kind.to_s : nil,
        urgency:           urgency,
        body:              body,                  # decrypted for the browser
        audio_url:         audio_url,             # nil unless an audio recording is attached
        created_at:        created_at.iso8601
      }
    )
  end
end
