class PharmacyDelivery < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail
  include AgentAuditable
  include BroadcastsPatientContext

  enum :kind, {
    comfort_kit: 0, refill: 1, new_fill: 2, emergency: 3
  }, prefix: true, validate: true

  enum :status, {
    requested: 0, en_route: 1, delivered: 2, refused: 3
  }, prefix: :delivery, validate: true

  belongs_to :agency
  belongs_to :patient
  belongs_to :medication_order, optional: true           # nil for comfort kits
  belongs_to :confirmed_by,     class_name: "User", optional: true
end
