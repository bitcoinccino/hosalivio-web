class Branch < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail

  enum :branch_type, {
    office:       0,  # Standard administrative office
    ipu:          1,  # Freestanding Inpatient Unit with beds
    satellite:    2,  # Small satellite location feeding a hub
    storage_hub:  3   # DME / supplies warehouse, non-clinical
  }, prefix: true, validate: true

  # The four Medicare hospice levels of care this branch can deliver. Tracked
  # per-branch (not per-agency) because GIP and Inpatient Respite depend on a
  # facility contract that can differ between branches of the same agency.
  # key => full label (form + "levels offered" display).
  LEVELS_OF_CARE = {
    "routine_home"    => "Routine Home Care",
    "continuous_home" => "Continuous Home Care",
    "gip"             => "General Inpatient (GIP)",
    "respite"         => "Inpatient Respite"
  }.freeze
  # Short labels for the compact public agency-card badges.
  LEVEL_BADGES = {
    "routine_home"    => "Routine",
    "continuous_home" => "Continuous",
    "gip"             => "GIP",
    "respite"         => "Respite"
  }.freeze

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
  # NPI / CCN are NOT unique at the branch level: in real hospice
  # operations, branches of the same agency commonly share the
  # corporate NPI and CCN unless a specific location is separately
  # Medicare-enrolled. Format-only validation; uniqueness is enforced
  # at the agency level on the Agency model.
  validate  :triage_email_shape
  validate  :service_area_zips_shape

  before_validation :normalize_arrays
  before_validation :nullify_blank_unique_ids

  scope :active, -> { where(active: true) }

  # Does this branch cover the given ZIP? Exact match OR 3-digit prefix match
  # (common in real hospice service-area definitions).
  def covers_zip?(zip)
    return false if zip.blank?
    z = zip.to_s.strip
    prefix = z[0, 3]
    (service_area_zips || []).any? { |entry| entry.to_s == z || entry.to_s == prefix }
  end

  # Does this branch deliver the given level of care? key is one of
  # LEVELS_OF_CARE.keys (e.g. "respite").
  def offers_level?(key)
    Array(levels_of_care).map(&:to_s).include?(key.to_s)
  end

  # Full labels, in canonical order, for display ("Routine Home Care", …).
  def levels_of_care_labels
    LEVELS_OF_CARE.keys.select { |k| offers_level?(k) }.map { |k| LEVELS_OF_CARE[k] }
  end

  # Short labels for the compact public-card badges ("Routine", "Respite", …).
  def levels_of_care_badges
    LEVELS_OF_CARE.keys.select { |k| offers_level?(k) }.map { |k| LEVEL_BADGES[k] }
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
    [ city, state ].compact_blank.join(", ").presence || name
  end

  def staff_count      = users.where(active: true).count
  def patient_count    = patients.count
  def service_area_summary
    counts = [ service_area_zips.size, service_area_counties.size ].sum
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
    # Keep only recognized level keys, in canonical order (drops the blank the
    # form submits to allow clearing, plus any unknown values).
    self.levels_of_care = LEVELS_OF_CARE.keys & split_listish(levels_of_care)
  end

  # The unique indexes on npi / ccn allow multiple NULLs but reject
  # multiple empty strings. Coerce blank submissions to nil so an
  # admin who leaves these fields empty doesn't trip the constraint
  # the second time around.
  def nullify_blank_unique_ids
    self.npi = nil if npi.is_a?(String) && npi.strip.empty?
    self.ccn = nil if ccn.is_a?(String) && ccn.strip.empty?
    self.ein = nil if ein.is_a?(String) && ein.strip.empty?
  end

  # Accepts either an array (from the tag input) or a comma/newline string
  # (legacy / pasted). Either way: trim, drop blanks, de-dupe.
  def split_listish(val)
    items = val.is_a?(Array) ? val : val.to_s.split(/[,\n]/)
    items.map { |v| v.to_s.strip }.reject(&:blank?).uniq
  end

  def triage_email_shape
    return if triage_email.blank?
    errors.add(:triage_email, "is not a valid email") unless triage_email =~ URI::MailTo::EMAIL_REGEXP
  end

  # Each service-area ZIP must be a 3-digit prefix or a full 5-digit ZIP.
  def service_area_zips_shape
    bad = Array(service_area_zips).reject { |z| z.to_s.match?(/\A\d{3}(?:\d{2})?\z/) }
    return if bad.empty?
    errors.add(:service_area_zips, "must be 3- or 5-digit ZIPs (bad: #{bad.join(', ')})")
  end
end
