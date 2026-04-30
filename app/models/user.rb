class User < ApplicationRecord
  # Devise
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable

  # Audit trail for human edits
  has_paper_trail

  # Associations
  belongs_to :agency, optional: true                         # nil only for system admins
  belongs_to :branch, optional: true                          # physical location within the agency
  belongs_to :patient, optional: true                         # set only when family_access

  has_many :user_roles, dependent: :destroy
  has_many :roles, through: :user_roles

  # Profile photo — optional. Images only, max 5 MB.
  has_one_attached :avatar
  validate :avatar_shape_and_size

  AVATAR_MIMES = %w[image/jpeg image/png image/webp image/gif].freeze
  AVATAR_MAX_BYTES = 5 * 1024 * 1024

  def avatar_shape_and_size
    return unless avatar.attached?
    errors.add(:avatar, "must be a JPEG, PNG, WebP, or GIF") unless AVATAR_MIMES.include?(avatar.content_type)
    errors.add(:avatar, "must be under 5 MB") if avatar.byte_size > AVATAR_MAX_BYTES
  end

  # Drawn e-signature — captured once via the profile signature pad,
  # reused on every clinical sign-off (PreAdmitEval certification,
  # Visit MD-routing, future late-entry notes). Stored as PNG so the
  # eval document can render it inline. The audit trail lives in the
  # `signatures` table, not on this attachment.
  has_one_attached :signature
  validate :signature_shape_and_size

  SIGNATURE_MIMES = %w[image/png image/jpeg].freeze
  SIGNATURE_MAX_BYTES = 512 * 1024  # 512 KB — drawn signatures should be tiny

  def signature_shape_and_size
    return unless signature.attached?
    errors.add(:signature, "must be a PNG or JPEG") unless SIGNATURE_MIMES.include?(signature.content_type)
    errors.add(:signature, "must be under 512 KB") if signature.byte_size > SIGNATURE_MAX_BYTES
  end

  def signature_registered?
    signature.attached? && signature_registered_at.present?
  end

  # True when `typed` matches this user's full_name modulo case
  # and whitespace (multiple spaces collapse, leading/trailing
  # trimmed). Used by Signatures::Gate so a sign-off can only
  # apply if the actor types their own name — closes the loop on
  # "is this really me, intending to sign right now?" beyond just
  # an intent checkbox.
  def matches_full_name?(typed)
    return false if typed.to_s.strip.empty?
    norm = ->(s) { s.to_s.downcase.split.join(" ") }
    norm.call(typed) == norm.call(full_name)
  end

  has_many :signatures, dependent: :destroy

  def initials
    full_name.to_s.split.map(&:first).first(2).join.upcase
  end

  def has_avatar?
    avatar.attached?
  end

  has_many :visits,                           inverse_of: :user
  has_many :prescribed_medication_orders,     class_name: "MedicationOrder", foreign_key: :prescribed_by_id
  has_many :administered_medication_logs,     class_name: "MedicationLog",   foreign_key: :administered_by_id
  has_many :outbound_pings,                   dependent: :destroy

  # Out-of-app notification channels (Telegram chat_id, WhatsApp /
  # SMS phone, email opt-in). HIPAA: only PHI-free preview strings
  # ever flow through these channels; the actual content stays
  # behind the deeplink + an authenticated HosAlivio session.
  CHANNEL_KEYS = %w[telegram whatsapp sms email].freeze

  def notification_channel(key)
    (notification_channels || {})[key.to_s] || {}
  end

  def channel_enabled?(key)
    !!notification_channel(key)["enabled"]
  end

  def enabled_channels
    CHANNEL_KEYS.select { |k| channel_enabled?(k) }
  end

  # Returns true if `now` falls inside the user's configured quiet
  # hours. Crisis pings ignore quiet hours; everything else gets
  # suppressed. Times are treated in the user's timezone (falls
  # back to UTC if unset).
  def in_quiet_hours?(now = Time.current)
    qh = (notification_channels || {})["quiet_hours"]
    return false unless qh.is_a?(Hash) && qh["start"].present? && qh["end"].present?
    tz = ActiveSupport::TimeZone[qh["timezone"].to_s] || ActiveSupport::TimeZone[timezone.to_s] || Time.zone
    local = now.in_time_zone(tz)
    start_min = parse_clock(qh["start"])
    end_min   = parse_clock(qh["end"])
    return false if start_min.nil? || end_min.nil?
    cur_min = local.hour * 60 + local.min
    if start_min < end_min
      cur_min >= start_min && cur_min < end_min
    else
      # Overnight window (e.g., 22:00 → 07:00)
      cur_min >= start_min || cur_min < end_min
    end
  end

  private

  def parse_clock(str)
    h, m = str.to_s.split(":").map(&:to_i)
    return nil unless h && m && h.between?(0, 23) && m.between?(0, 59)
    h * 60 + m
  end

  public

  # Tenant scope: non-system users are constrained to their agency
  acts_as_tenant :agency, has_global_records: true

  # Validations
  validates :full_name, presence: true
  validates :timezone,  presence: true
  validate  :family_users_must_reference_a_patient

  # --- Employment + compliance --------------------------------------------
  enum :employment_type, {
    full_time: 0, part_time: 1, contract: 2, prn: 3
  }, prefix: true, validate: true

  validates :npi,            format: { with: /\A\d{10}\z/, message: "must be 10 digits" }, allow_blank: true
  validates :phone_number,   format: { with: /\A[\d\-\+\(\)\s\.]{7,20}\z/, message: "looks invalid" }, allow_blank: true
  validates :max_caseload,   numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 200 }

  before_validation :normalize_service_zips

  scope :on_call_now, -> { where(on_call: true, active: true) }
  scope :license_expiring_within, ->(days) {
    return none if days.blank?
    where(license_expires_on: Date.current..(Date.current + days.to_i.days))
  }
  scope :license_expired, -> { where("license_expires_on < ?", Date.current) }

  # --- Role helpers -------------------------------------------------------
  def has_role?(name) = roles.exists?(name: name.to_s)
  def role_names      = roles.pluck(:name)

  # --- Compliance helpers -------------------------------------------------
  def license_expired? = license_expires_on && license_expires_on < Date.current
  def license_expiring_soon?(within: 60)
    return false unless license_expires_on
    license_expires_on <= Date.current + within.days && !license_expired?
  end

  def license_status
    return :none      unless license_expires_on
    return :expired   if license_expired?
    return :expiring  if license_expiring_soon?(within: 30)
    return :warning   if license_expiring_soon?(within: 60)
    :ok
  end

  # --- Caseload -----------------------------------------------------------
  # Count patients where this user holds any case-management role.
  # Used for Diaphnie's caseload balancing.
  def current_caseload
    return 0 unless agency_id
    Patient.unscoped.where(agency_id: agency_id).where(
      "assigned_rn_id = :id OR assigned_md_id = :id OR assigned_sw_id = :id OR assigned_chaplain_id = :id",
      id: id
    ).count
  end

  def caseload_utilization
    return 0.0 if max_caseload.to_i.zero?
    (current_caseload.to_f / max_caseload).round(2)
  end

  def at_capacity? = current_caseload >= max_caseload.to_i

  # --- Geographic coverage ------------------------------------------------
  # A nurse may cover only certain ZIPs inside a branch's territory.
  def covers_zip?(zip)
    return true if service_zips.blank?  # no preference = covers the whole branch
    z = zip.to_s.strip
    prefix = z[0, 3]
    Array(service_zips).any? { |entry| entry.to_s == z || entry.to_s == prefix }
  end

  private

  def normalize_service_zips
    return if service_zips.is_a?(Array) && !service_zips.any? { |v| v.is_a?(String) && v.match?(/[,\n]/) }
    raw = service_zips
    return if raw.blank?
    self.service_zips = Array(raw).flat_map { |v| v.to_s.split(/[,\n]/) }
                                  .map(&:strip).reject(&:blank?).uniq
  end

  def family_users_must_reference_a_patient
    if family_access && patient_id.blank?
      errors.add(:patient_id, "is required for family portal users")
    elsif !family_access && patient_id.present?
      errors.add(:patient_id, "must be blank unless family_access is true")
    end
  end
end
