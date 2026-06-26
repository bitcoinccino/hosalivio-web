class MedicationOrder < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail
  include AgentAuditable
  include BroadcastsPatientContext

  enum :route, {
    po: 0, sl: 1, sc: 2, iv: 3, im: 4, pr: 5, top: 6, neb: 7, other: 8
  }, prefix: true, validate: true

  enum :status, { active: 0, dc: 1, hold: 2 }, prefix: :order, validate: true

  belongs_to :agency
  belongs_to :patient
  belongs_to :prescribed_by, class_name: "User"

  has_many :medication_logs, dependent: :restrict_with_error

  validates :drug_name, :dose, :frequency, :start_date, presence: true
  validate  :end_after_start

  private

  def end_after_start
    return unless end_date && start_date && end_date < start_date
    errors.add(:end_date, "must be on or after start_date")
  end
end
