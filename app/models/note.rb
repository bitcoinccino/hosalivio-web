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
  # For humans it's their clinical role ("RN", "MD"). For AI it's flagged.
  def display_author_subtitle
    return nil if author_role == "family"
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
        urgency:           urgency,
        body:              body,                  # decrypted for the browser
        created_at:        created_at.iso8601
      }
    )
  end
end
