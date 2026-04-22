class MedicationLog < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail
  include AgentAuditable

  # AgentAuditable expects agency_id directly; medication_log has it.

  enum :source, {
    comfort_kit: 0, home_supply: 1, pharmacy_delivery: 2
  }, prefix: true, validate: true

  belongs_to :agency
  belongs_to :medication_order
  belongs_to :administered_by, class_name: "User"

  has_one :patient, through: :medication_order

  validates :administered_at, :dose_given, presence: true
end
