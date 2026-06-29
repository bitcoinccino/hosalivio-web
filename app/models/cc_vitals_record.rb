# A single interval vitals/data check-in within a CC shift (charted ~q2h).
class CcVitalsRecord < ApplicationRecord
  acts_as_tenant :agency
  belongs_to :agency
  belongs_to :cc_interval_chart

  validates :recorded_at, presence: true
  validates :pulse, :respiration,
            numericality: { only_integer: true, greater_than: 0, allow_nil: true }
end
