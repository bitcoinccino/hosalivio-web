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

  # Live-replace the unread-count bell badge on a user's stream. Called on
  # create (count up) and after the mark-read actions (count down). Uses an
  # explicit agency/user scope so it's tenant-safe inside model callbacks.
  def self.broadcast_badge(agency_id:, user_id:)
    count = unscoped.where(agency_id: agency_id, user_id: user_id, read_at: nil).count
    Turbo::StreamsChannel.broadcast_replace_to(
      "notifications:user:#{user_id}",
      target:  "notif-bell-badge",
      partial: "notifications/bell_badge",
      locals:  { count: count }
    )
  rescue => e
    Rails.logger.warn("[Notification.broadcast_badge] #{e.class}: #{e.message}")
  end

  private

  def broadcast_realtime
    stream = "notifications:user:#{user_id}"
    # Toast on whatever page they're on.
    Turbo::StreamsChannel.broadcast_append_to(
      stream, target: "notification-toasts",
      partial: "notifications/toast", locals: { notification: self }
    )
    # Live-prepend the row + clear the empty state for anyone on the inbox.
    Turbo::StreamsChannel.broadcast_prepend_to(
      stream, target: "notifications-list",
      partial: "notifications/notification", locals: { notification: self }
    )
    Turbo::StreamsChannel.broadcast_remove_to(stream, target: "notif-empty-state")
    self.class.broadcast_badge(agency_id: agency_id, user_id: user_id)
  rescue => e
    # A live-delivery failure must never break the create or the outbound ping.
    Rails.logger.warn("[Notification#broadcast_realtime] #{e.class}: #{e.message}")
  end

  def enqueue_outbound_ping
    return if user&.enabled_channels.blank?
    OutboundPings::Enqueuer.from_notification(self)
  end
end
