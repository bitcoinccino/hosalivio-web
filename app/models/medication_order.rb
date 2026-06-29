class MedicationOrder < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail
  include AgentAuditable
  include BroadcastsPatientContext

  enum :route, {
    po: 0, sl: 1, sc: 2, iv: 3, im: 4, pr: 5, top: 6, neb: 7, other: 8
  }, prefix: true, validate: true

  # :draft is a suggested-but-unauthorized order (e.g. a comfort-kit item the
  # intake nurse selected). It carries no prescribing authority until an MD
  # authorizes it, which flips it to :active and applies their signature.
  enum :status, { active: 0, dc: 1, hold: 2, draft: 3 }, prefix: :order, validate: true

  belongs_to :agency
  belongs_to :patient
  belongs_to :prescribed_by, class_name: "User"
  belongs_to :pre_admit_eval, optional: true   # the admission this was ordered during

  has_many :medication_logs, dependent: :restrict_with_error
  has_many :signatures, as: :signable, dependent: :destroy

  scope :comfort_kit, -> { where(comfort_kit: true) }
  scope :controlled,  -> { where(controlled: true) }

  validates :drug_name, :dose, :frequency, :start_date, presence: true
  validate  :end_after_start

  private

  def end_after_start
    return unless end_date && start_date && end_date < start_date
    errors.add(:end_date, "must be on or after start_date")
  end
end
