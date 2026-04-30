# Patient/family consent capture (Hospice Election, DNR, HIPAA,
# Plan of Care). Unlike clinician sign-offs we don't reuse a stored
# signature — patient/family always sign fresh, in front of a
# witnessing clinician (`witnessed_by`). The drawn signature image
# attaches to this record one-time; the audit metadata lands on a
# polymorphic `Signature` row exactly the same shape every other
# sign-off in the app uses.
class ConsentForm < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail

  belongs_to :patient
  belongs_to :witnessed_by, class_name: "User"
  belongs_to :agency

  has_one_attached :signature_image
  has_many :signatures, as: :signable, dependent: :destroy

  KINDS = %w[hospice_election dnr hipaa_acknowledgment plan_of_care].freeze
  KIND_LABELS = {
    "hospice_election"      => "Hospice Election of Benefit",
    "dnr"                   => "DNR / Code Status",
    "hipaa_acknowledgment"  => "HIPAA Acknowledgment",
    "plan_of_care"          => "Plan of Care"
  }.freeze

  # Patient = the patient themselves. Everything else means a
  # representative is signing on the patient's behalf — relationship
  # + authority columns capture the why so a CMS auditor can tell
  # at a glance whether the surrogate had standing to sign.
  SIGNER_ROLES = %w[
    patient spouse son daughter parent sibling
    healthcare_proxy poa legal_guardian other_family
  ].freeze

  validates :kind,        inclusion: { in: KINDS }
  validates :signer_role, inclusion: { in: SIGNER_ROLES }
  validates :signer_name, presence: true, length: { minimum: 2, maximum: 200 }
  validates :signer_authority, presence: true, if: -> { !signed_by_patient? }
  validates :signed_at, presence: true

  before_validation :default_signed_at, :stamp_agency

  scope :recent_first, -> { order(signed_at: :desc) }

  def signed_by_patient?
    signer_role == "patient"
  end

  def kind_label
    KIND_LABELS[kind] || kind.to_s.tr("_", " ").titleize
  end

  def signer_label
    return signer_name if signed_by_patient?
    rel = signer_relationship.presence || signer_role.tr("_", " ").titleize
    "#{signer_name} (#{rel})"
  end

  private

  def default_signed_at = self.signed_at ||= Time.current

  def stamp_agency
    self.agency_id ||= patient&.agency_id
  end
end
