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

  validates :author_role, presence: true
  validates :body, presence: true

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
  # Used by the chat UI to label bubbles "HosAlivio Assist" instead of
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
    ai_authored? ? "HosAlivio Assist" : author_role.to_s.upcase
  end

  # Role sub-label shown in parentheses under the speaker's name.
  # For family it's their relationship to the patient ("Son of Maria");
  # for clinicians it's the clinical role ("RN", "MD"); AI is flagged.
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
        urgency:           urgency,
        body:              body,                  # decrypted for the browser
        created_at:        created_at.iso8601
      }
    )
  end
end
