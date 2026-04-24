class Agency < ApplicationRecord
  has_paper_trail

  # Tiering for future plans / feature gating
  enum :billing_tier, { starter: 0, pro: 1, enterprise: 2 }, validate: true

  # Operational configuration captured during partner signup. All optional —
  # agencies that skip a field just opt out of the corresponding agent's
  # specialized behavior (e.g., no pharmacy_partner means Simone can't
  # auto-route refills to a vendor API; she falls back to generic email).
  enum :accreditation_body, { joint_commission: 0, chap: 1, achc: 2, state_only: 3 },
       prefix: :accredited_by, validate: { allow_nil: true }
  enum :mac_region, { palmetto_gba: 0, cgs: 1, ngs: 2, noridian: 3 },
       prefix: :mac, validate: { allow_nil: true }
  enum :emr_system, { hchb: 0, netsmart: 1, matrixcare: 2, wellsky: 3, standalone: 4 },
       prefix: :emr, validate: { allow_nil: true }
  enum :pharmacy_partner, { optum: 0, enclara: 1, local_pharmacy: 2 },
       prefix: :pharmacy_vendor, validate: { allow_nil: true }
  enum :dme_partner, { stateserv: 0, qualis: 1, local_dme: 2 },
       prefix: :dme_vendor, validate: { allow_nil: true }

  # Children
  has_many :branches,    dependent: :destroy
  has_many :users,       dependent: :restrict_with_error
  has_many :patients,    dependent: :restrict_with_error
  has_many :user_roles,  dependent: :destroy
  has_many :visits,              dependent: :restrict_with_error
  has_many :medication_orders,   dependent: :restrict_with_error
  has_many :medication_logs,     dependent: :restrict_with_error
  has_many :pharmacy_deliveries, dependent: :restrict_with_error
  has_many :dme_orders,          dependent: :restrict_with_error
  has_many :agent_events,        dependent: :destroy
  has_many :pre_admit_evals,     dependent: :restrict_with_error

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[A-Z0-9]{2,6}\z/ }

  # ── Partner-directory scopes (used on the public landing page) ────────
  scope :partners,                 -> { where(is_partner: true, active: true) }
  scope :accepting_referrals,      -> { where(accepting_referrals: true) }
  scope :with_specialty,           ->(s) { where("specialties  @> ?", [s].to_json) }
  scope :with_insurance,           ->(i) { where("insurance_accepted @> ?", [i].to_json) }
  scope :with_language,            ->(l) { where("languages @> ?", [l].to_json) }
  scope :serving_zip_prefix, lambda { |prefix|
    next none if prefix.blank?
    where("service_area_zips @> ? OR service_area_zips @> ? OR zip LIKE ?",
          [prefix].to_json, [prefix[0, 3]].to_json, "#{prefix}%")
  }

  SPECIALTY_CATALOG = {
    "general_hospice"   => "General Hospice",
    "dementia_care"     => "Dementia & Alzheimer's",
    "pediatric"         => "Pediatric Hospice",
    "cardiac"           => "Cardiac / CHF",
    "oncology"          => "Oncology",
    "veterans"          => "Veterans Care",
    "lgbtq_affirming"   => "LGBTQ+ Affirming",
    "rural_coverage"    => "Rural / Wide-area",
    "palliative_bridge" => "Palliative Bridge"
  }.freeze

  INSURANCE_CATALOG = {
    "medicare" => "Medicare",
    "medicaid" => "Medicaid",
    "private"  => "Private Insurance",
    "va"       => "VA Benefits",
    "selfpay"  => "Self-pay"
  }.freeze

  LANGUAGE_CATALOG = {
    "en" => "English",
    "es" => "Spanish",
    "ht" => "Haitian Creole",
    "pt" => "Portuguese",
    "zh" => "Chinese",
    "fr" => "French"
  }.freeze

  # ── Per-agency agent customization ───────────────────────────────────
  # agent_personas and agent_overrides are jsonb columns keyed by role.
  # This wraps them so callers can read/write without raw hash digs.
  def persona_for(role)  = (agent_personas.presence || {})[role.to_s] || {}
  def override_for(role) = (agent_overrides.presence || {})[role.to_s].to_s

  def set_persona(role, attrs)
    self.agent_personas = (agent_personas || {}).merge(role.to_s => attrs.stringify_keys)
  end

  def set_override(role, text)
    self.agent_overrides = (agent_overrides || {}).merge(role.to_s => text.to_s)
  end

  # ── Feature flags ────────────────────────────────────────────────────
  # features is a jsonb column. Each key is a feature name, each value a hash:
  #   { "enabled" => true, "baa_signed_on" => "2026-05-01", "provider" => "openai" }
  # Safe defaults (everything off) so adding a new tenant never accidentally
  # enables PHI-exposing features.

  def feature_enabled?(name)
    cfg = feature_config(name)
    !!cfg["enabled"]
  end

  def feature_config(name)
    (features.presence || {})[name.to_s] || {}
  end

  def set_feature(name, attrs)
    existing = feature_config(name)
    self.features = (features.presence || {}).merge(name.to_s => existing.merge(attrs.stringify_keys))
  end

  def enable_feature!(name, **attrs)
    set_feature(name, attrs.merge(enabled: true))
    save!
  end

  def disable_feature!(name)
    set_feature(name, enabled: false, disabled_at: Time.current.iso8601)
    save!
  end

  # MRN generator — sequential per agency. Called by Patient#set_mrn.
  def next_mrn
    last_seq = patients.where("mrn LIKE ?", "#{slug}-%")
                       .pluck(:mrn)
                       .map { |m| m.split("-").last.to_i }
                       .max || 0
    format("%s-%05d", slug, last_seq + 1)
  end
end
