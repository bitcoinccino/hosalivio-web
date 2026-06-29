# Continuous Care (CC) interval shift chart — the parent "sheet" a clinician
# fills for one CC shift. Stays a :draft until electronically signed (reuses the
# polymorphic Signature model, same as visits/evals). Name/MRN come from the
# patient; the signer + discipline come from the Signature, not flat strings.
class CcIntervalChart < ApplicationRecord
  acts_as_tenant :agency
  belongs_to :agency
  belongs_to :patient
  belongs_to :user                 # the charting clinician (visit RN / LPN / CNA)
  belongs_to :visit, optional: true

  has_many :cc_vitals_records,             dependent: :destroy
  has_many :cc_poc_interventions,          dependent: :destroy
  has_many :cc_controlled_substance_counts, dependent: :destroy
  has_many :signatures, as: :signable,     dependent: :destroy

  enum :status, { draft: 0, signed: 1 }, prefix: true, validate: true

  accepts_nested_attributes_for :cc_vitals_records,              allow_destroy: true
  accepts_nested_attributes_for :cc_poc_interventions,           allow_destroy: true
  accepts_nested_attributes_for :cc_controlled_substance_counts, allow_destroy: true

  validates :date_of_shift, presence: true
end
