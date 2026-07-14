# A one-time onboarding invite for the self-serve partner signup wizard.
#
# Flow: an agency expresses interest (demo/contact) → sales creates an
# invite and sends its link (/partners/new?token=…) AFTER the agreement is
# signed → the visitor completes the wizard → the invite is consumed
# (used_at set, agency linked) so the link can't provision a second agency.
#
# Deliberately NOT tenant-scoped: an invite exists before any Agency does.
class PartnerInvite < ApplicationRecord
  belongs_to :agency, optional: true

  before_validation :ensure_token, on: :create
  validates :token, presence: true, uniqueness: true

  # Unused and unexpired.
  scope :usable, -> {
    where(used_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current)
  }

  # Look up a usable invite by its raw token, or nil. Constant-ish: a
  # non-existent token and a used/expired one both return nil.
  def self.find_usable(raw_token)
    return nil if raw_token.blank?
    usable.find_by(token: raw_token)
  end

  def self.generate_unique_token
    loop do
      candidate = SecureRandom.urlsafe_base64(24)
      break candidate unless exists?(token: candidate)
    end
  end

  def usable?
    used_at.nil? && (expires_at.nil? || expires_at.future?)
  end

  def expired?
    expires_at.present? && expires_at.past?
  end

  # Mark the invite spent and tie it to the agency it created. Idempotent
  # guard: raises if already used, so a race can't consume it twice.
  def consume!(agency)
    raise ActiveRecord::RecordInvalid, self if used_at.present?
    update!(used_at: Time.current, agency: agency)
  end

  def signup_url(host:)
    "#{host.to_s.chomp('/')}/partners/new?token=#{token}"
  end

  private

  def ensure_token
    self.token ||= self.class.generate_unique_token
  end
end
