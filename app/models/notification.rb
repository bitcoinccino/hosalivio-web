class Notification < ApplicationRecord
  acts_as_tenant :agency

  belongs_to :agency
  belongs_to :user
  belongs_to :linked, polymorphic: true, optional: true

  validates :kind, :title, presence: true

  scope :unread,     -> { where(read_at: nil) }
  scope :newest_first, -> { order(created_at: :desc) }

  # Out-of-band ping fan-out: every notification creates an
  # OutboundPing row that the openclaw layer will poll + send via
  # the recipient's preferred channel (Telegram, SMS, email).
  # PHI-free preview only; details stay behind the deeplink.
  after_create_commit :enqueue_outbound_ping

  def read?  = read_at.present?
  def mark_read!(at = Time.current) = update!(read_at: at)

  private

  def enqueue_outbound_ping
    return if user&.enabled_channels.blank?
    OutboundPings::Enqueuer.from_notification(self)
  end
end
