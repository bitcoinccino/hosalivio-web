class DmeOrder < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail
  include AgentAuditable

  enum :equipment_type, {
    hospital_bed:     0,
    o2_concentrator:  1,
    wheelchair:       2,
    bsc:              3,    # bedside commode
    hoyer_lift:       4,
    walker:           5,
    shower_chair:     6,
    suction_machine:  7,
    nebulizer:        8,
    cpap:             9,
    other:           10
  }, prefix: true, validate: true

  enum :status, {
    requested: 0, approved: 1, delivered: 2, picked_up: 3, returned: 4
  }, prefix: :dme, validate: true

  belongs_to :agency
  belongs_to :patient

  validates :quantity, numericality: { greater_than: 0 }
  validates :requested_at, presence: true
end
