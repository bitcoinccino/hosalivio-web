class Branch < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail

  enum :branch_type, {
    office:       0,  # Standard administrative office
    ipu:          1,  # Freestanding Inpatient Unit with beds
    satellite:    2,  # Small satellite location feeding a hub
    storage_hub:  3   # DME / supplies warehouse, non-clinical
  }, prefix: true, validate: true

  belongs_to :agency
  belongs_to :manager,             class_name: "User", optional: true
  belongs_to :medical_director,    class_name: "User", optional: true
  belongs_to :director_of_nursing, class_name: "User", optional: true
  belongs_to :clinical_supervisor, class_name: "User", optional: true

  has_many :users,    dependent: :nullify
  has_many :patients, dependent: :nullify

  validates :name,     presence: true, uniqueness: { scope: :agency_id, case_sensitive: false }
  validates :timezone, presence: true
  validates :npi, format: { with: /\A\d{10}\z/, message: "must be 10 digits" }, allow_blank: true
  validates :ccn, format: { with: /\A[A-Z0-9]{5,10}\z/, message: "invalid Medicare CCN format" }, allow_blank: true
  validates :ein, format: { with: /\A\d{2}-?\d{7}\z/, message: "must be XX-XXXXXXX" }, allow_blank: true
  validate  :triage_email_shape

  before_validation :normalize_arrays

  scope :active, -> { where(active: true) }

  # Does this branch cover the given ZIP? Exact match OR 3-digit prefix match
  # (common in real hospice service-area definitions).
  def covers_zip?(zip)
    return false if zip.blank?
    z = zip.to_s.strip
    prefix = z[0, 3]
    (service_area_zips || []).any? { |entry| entry.to_s == z || entry.to_s == prefix }
  end

  def covers_county?(county)
    return false if county.blank?
    (service_area_counties || []).map(&:to_s).map(&:downcase).include?(county.to_s.downcase)
  end

  # Resolve which branch inside an agency should take a given ZIP. Falls back
  # to the agency's first branch if no branch claims coverage.
  def self.route_for_zip(agency, zip)
    candidates = where(agency: agency, active: true).to_a
    candidates.find { |b| b.covers_zip?(zip) } || candidates.first
  end

  def location_label
    [city, state].compact_blank.join(", ").presence || name
  end

  def staff_count      = users.where(active: true).count
  def patient_count    = patients.count
  def service_area_summary
    counts = [service_area_zips.size, service_area_counties.size].sum
    return "No service area set" if counts.zero?
    parts = []
    parts << "#{service_area_zips.size} ZIP#{'s' if service_area_zips.size != 1}" if service_area_zips.any?
    parts << "#{service_area_counties.size} countie#{'s' if service_area_counties.size != 1}" if service_area_counties.any?
    parts.join(" · ")
  end

  private

  # Form inputs come in as comma/newline-delimited strings; store as arrays.
  def normalize_arrays
    self.service_area_zips     = split_listish(service_area_zips)
    self.service_area_counties = split_listish(service_area_counties)
  end

  def split_listish(val)
    return [] if val.blank?
    return val if val.is_a?(Array)
    val.to_s.split(/[,\n]/).map(&:strip).reject(&:blank?).uniq
  end

  def triage_email_shape
    return if triage_email.blank?
    errors.add(:triage_email, "is not a valid email") unless triage_email =~ URI::MailTo::EMAIL_REGEXP
  end
end
