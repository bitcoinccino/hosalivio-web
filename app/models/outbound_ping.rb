# Queue of out-of-band pings to send to clinicians via channels they
# already check (Telegram, WhatsApp, SMS, email). Rails enqueues a
# row whenever a user-facing event lands that's worth interrupting
# them for (crisis chat, handoff, recert deadline). The openclaw
# layer polls undelivered rows, formats per the user's channel
# preferences, and posts the ping.
#
# HIPAA gate: `preview` is the only string that goes through the
# channel. It MUST be PHI-free ("1 urgent message awaiting your
# reply"). Patient names, diagnoses, and clinical content stay
# behind the deeplink + signed-in HosAlivio session.
class OutboundPing < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail

  KINDS = %w[crisis urgent handoff recert visit_starting mention].freeze
  CRISIS_KINDS = %w[crisis].freeze

  belongs_to :agency
  belongs_to :user

  validates :kind,    inclusion: { in: KINDS }
  validates :preview, presence: true, length: { maximum: 200 }
  validates :link_token, presence: true, uniqueness: true
  validates :link_expires_at, presence: true

  before_validation :stamp_link_token,      on: :create
  before_validation :stamp_link_expiration, on: :create

  scope :pending,   -> { where(delivered_at: nil) }
  scope :delivered, -> { where.not(delivered_at: nil) }
  scope :recent,    -> { order(created_at: :desc) }

  def crisis?
    CRISIS_KINDS.include?(kind)
  end

  def expired?
    link_expires_at < Time.current
  end

  def consumed?
    consumed_at.present?
  end

  def usable?
    !expired? && !consumed?
  end

  def consume!
    update!(consumed_at: Time.current)
  end

  def mark_delivered!(channels)
    update!(
      delivered_at:       Time.current,
      delivered_channels: Array(channels).map(&:to_s).uniq
    )
  end

  private

  def stamp_link_token
    self.link_token ||= SecureRandom.urlsafe_base64(24)
  end

  def stamp_link_expiration
    self.link_expires_at ||= 5.minutes.from_now
  end
end
