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

  scope :unread, -> { where(read_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  after_create_commit :broadcast_to_patient_channel

  def mark_read!(user = nil)
    update!(read_at: Time.current) if read_at.nil?
  end

  private

  def broadcast_to_patient_channel
    ActionCable.server.broadcast(
      "patient:#{patient_id}",
      {
        kind:        "note",
        note_id:     id,
        author_role: author_role,
        urgency:     urgency,
        body:        body,                         # decrypted for the browser
        created_at:  created_at.iso8601
      }
    )
  end
end
