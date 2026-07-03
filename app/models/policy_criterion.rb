# One requirement within a CoveragePolicy — the unit the document-evidence
# extractor (Stage 2) checks and the reviewer signs off on. `keywords` anchor
# retrieval; `evidence_type` hints how the value is read (a count, a date
# window, a score, or free text).
class PolicyCriterion < ApplicationRecord
  # Rails would infer "policy_criterions"; the table is the Latin plural.
  self.table_name = "policy_criteria"

  belongs_to :coverage_policy, inverse_of: :criteria

  EVIDENCE_TYPES = %w[count date_window score text].freeze

  validates :label, presence: true
  validates :evidence_type, inclusion: { in: EVIDENCE_TYPES }, allow_blank: true

  # The shape Stage 2 hands the extractor for retrieval + criterion-anchored
  # matching. String id so it round-trips cleanly through the LLM JSON.
  def to_extraction_spec
    {
      criterion_id: id,
      label:        label,
      description:  description,
      keywords:     Array(keywords),
      evidence_type: evidence_type
    }
  end
end
