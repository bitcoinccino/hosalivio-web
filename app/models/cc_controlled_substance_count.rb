# Shift-level narcotic count (start/end) for a CC shift. Optionally linked to
# the patient's active controlled MedicationOrder so the count reconciles
# against the MAR (the MedicationLog stays the source of truth for doses given).
class CcControlledSubstanceCount < ApplicationRecord
  acts_as_tenant :agency
  belongs_to :agency
  belongs_to :cc_interval_chart
  belongs_to :medication_order, optional: true

  validates :drug_name, presence: true
  validates :count_at_start, :count_at_end,
            numericality: { only_integer: true, greater_than_or_equal_to: 0, allow_nil: true }
end
