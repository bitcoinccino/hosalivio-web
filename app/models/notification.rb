class Notification < ApplicationRecord
  acts_as_tenant :agency

  belongs_to :agency
  belongs_to :user
  belongs_to :linked, polymorphic: true, optional: true

  validates :kind, :title, presence: true

  scope :unread,     -> { where(read_at: nil) }
  scope :newest_first, -> { order(created_at: :desc) }

  # In-app real-time delivery: the instant a notification is created, push a
  # toast to the recipient's per-user Turbo stream so it shows up live on
  # whatever page they're on (no reload, no waiting on the external ping).
  after_create_commit :broadcast_realtime

  # Out-of-band ping fan-out: every notification creates an
  # OutboundPing row that the openclaw layer will poll + send via
  # the recipient's preferred channel (Telegram, SMS, email).
  # PHI-free preview only; details stay behind the deeplink.
  after_create_commit :enqueue_outbound_ping

  def read?  = read_at.present?
  def mark_read!(at = Time.current) = update!(read_at: at)

  private

  def broadcast_realtime
    Turbo::StreamsChannel.broadcast_append_to(
      "notifications:user:#{user_id}",
      target:  "notification-toasts",
      partial: "notifications/toast",
      locals:  { notification: self }
    )
  rescue => e
    # A live-toast failure must never break the create or the outbound ping.
    Rails.logger.warn("[Notification#broadcast_realtime] #{e.class}: #{e.message}")
  end

  def enqueue_outbound_ping
    return if user&.enabled_channels.blank?
    OutboundPings::Enqueuer.from_notification(self)
  end
end
