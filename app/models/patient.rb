class Patient < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail
  include AgentAuditable

  # --- Encrypted PHI fields ------------------------------------------------
  # `deterministic: true` on identifiers allows equality lookup (e.g. search by phone);
  # narrative/clinical text uses the default non-deterministic (stronger) mode.
  encrypts :first_name,         deterministic: true
  encrypts :last_name,          deterministic: true
  # dob is stored encrypted in a string column; cast to Date for app code.
  attribute :dob, :date
  encrypts :dob,                deterministic: true
  encrypts :address_line1
  encrypts :address_line2
  encrypts :city
  encrypts :state
  encrypts :zip
  encrypts :phone,              deterministic: true
  encrypts :email,              deterministic: true
  encrypts :primary_diagnosis
  encrypts :secondary_diagnoses
  encrypts :caregiver_name
  encrypts :caregiver_phone

  # --- Enums ---------------------------------------------------------------
  enum :benefit_period, { bp1_90: 0, bp2_90: 1, bp3_60n: 2 }, validate: { allow_nil: true }
  enum :status, {
    referred: 0, admitted: 1, active: 2, revoked: 3, discharged: 4, deceased: 5
  }, validate: true
  enum :code_status, {
    full_code: 0, dnr: 1, dni: 2, dnr_dni: 3, comfort_only: 4
  }, validate: true

  # --- Associations --------------------------------------------------------
  belongs_to :agency
  belongs_to :branch,            optional: true
  belongs_to :assigned_rn,       class_name: "User", optional: true
  belongs_to :assigned_md,       class_name: "User", optional: true
  belongs_to :assigned_sw,       class_name: "User", optional: true
  belongs_to :assigned_chaplain, class_name: "User", optional: true

  has_many :visits,              dependent: :destroy
  has_many :medication_orders,   dependent: :destroy
  has_many :medication_logs,     through: :medication_orders
  has_many :pharmacy_deliveries, dependent: :destroy
  has_many :dme_orders,          dependent: :destroy
  has_many :notes,               dependent: :destroy
  has_many :family_users, class_name: "User"

  # --- Validations ---------------------------------------------------------
  validates :first_name, :last_name, :dob, presence: true
  validates :mrn, presence: true, uniqueness: { scope: :agency_id }

  # --- Callbacks -----------------------------------------------------------
  before_validation :assign_mrn, on: :create

  # --- Derived helpers -----------------------------------------------------
  def full_name = "#{first_name} #{last_name}"
  def age_years = dob ? ((Date.current - dob).to_i / 365) : nil

  private

  def assign_mrn
    return if mrn.present?
    self.mrn = agency&.next_mrn
  end
end
