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

  # Threading: a reply points at the root note it answers. Threads are one
  # level deep — a reply can't itself be replied to (enforced below). Replies
  # inherit their parent's patient/agency/visibility so a team-only thread
  # stays team-only and a family thread stays family-visible.
  belongs_to :parent_note, class_name: "Note", optional: true
  has_many   :replies, class_name: "Note", foreign_key: :parent_note_id,
                       inverse_of: :parent_note, dependent: :nullify

  before_validation :inherit_thread_attributes, on: :create, if: :parent_note_id?
  validate :thread_is_one_level_deep
  validate :reply_matches_parent_patient

  scope :roots, -> { where(parent_note_id: nil) }

  def reply?       = parent_note_id.present?
  def thread_root? = parent_note_id.blank?
  # The clinician who scored this note's quality (thumbs up/down on
  # AI replies). Distinct from author_user — feedback can come from a
  # different clinician than the one who wrote (or in the AI case, the
  # one who triggered) the message.
  belongs_to :feedback_by, class_name: "User", optional: true

  # Standardized reason codes for thumbs-down feedback. Free text in
  # `feedback_notes` captures anything not in this list. Adding a new
  # code here is safe; removing one would orphan historical rows so
  # don't do that without a backfill.
  FEEDBACK_REASONS = %w[
    factually_wrong
    tone
    too_clinical
    too_vague
    wrong_audience
    missing_context
    other
  ].freeze

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
  # Page mentioned clinicians out-of-app when this note is a
  # clinician-only crisis or urgent message containing @mentions.
  # Family-facing notes go through HosalivioTriager which has its own
  # pathway; we don't want to ping for routine charts.
  after_create_commit :enqueue_outbound_pings_for_mentions

  # A family crisis note (and marking one read) changes the RN's live
  # "Needs action now" crisis count — push it over their Turbo Stream.
  after_create_commit :broadcast_rn_needs_action
  after_update_commit :broadcast_rn_needs_action, if: -> { saved_change_to_read_at? }

  def broadcast_rn_needs_action
    return unless author_role.to_s == "family" && urgency.to_s == "crisis"
    DashboardData.broadcast_needs_action(patient&.assigned_rn)
  rescue => e
    Rails.logger.warn("[Note#broadcast_rn_needs_action] #{e.class}: #{e.message}")
  end

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
  GUARDRAIL_PREFIX  = "[GUARDRAIL_BLOCKED]"
  HOSALIVIO_ACK_PREFIX = "[HOSALIVIO_ACK]"
  def audit_kind
    return :action     if action_banner?
    txt = body.to_s
    return :guardrail  if txt.start_with?(GUARDRAIL_PREFIX)
    return :hosalivio_ack if txt.start_with?(HOSALIVIO_ACK_PREFIX)
    return :triage     if txt.lines.any? { |l| l.start_with?("Notified:") }
    return :rationale  if txt.match?(RATIONALE_BODY_RE)
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

  # A reply inherits the thread's patient/agency and — critically — its
  # visibility, so replying never moves a note across the family/clinician
  # boundary. Set before validation so the inheritance is what gets saved.
  def inherit_thread_attributes
    root = parent_note
    return unless root
    self.patient_id     = root.patient_id
    self.agency_id      = root.agency_id
    self.clinician_only = root.clinician_only
  end

  # One level deep: the parent must itself be a root. Prevents reply-to-reply
  # chains the threaded UI isn't built to render.
  def thread_is_one_level_deep
    return if parent_note_id.blank?
    return unless parent_note&.parent_note_id.present?
    errors.add(:parent_note_id, "can't reply to a reply (threads are one level deep)")
  end

  def reply_matches_parent_patient
    return if parent_note_id.blank? || parent_note.nil?
    if parent_note.patient_id != patient_id
      errors.add(:parent_note_id, "must belong to the same patient")
    end
  end

  def enqueue_outbound_pings_for_mentions
    return unless clinician_only
    return unless %w[urgent crisis].include?(urgency.to_s)
    OutboundPings::Enqueuer.from_note(self)
  end

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
        parent_note_id:    parent_note_id,    # nil = top-level; else nests under that note
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
