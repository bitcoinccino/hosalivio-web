# A coverage/medical-necessity policy expressed as data (see
# docs/prior-auth-slice.md) — a Medicare LCD/NCD and the criteria a request must
# satisfy. Global reference data (not tenant-scoped), like Icd10Code; commercial
# per-agency policies can add an optional agency_id later.
#
# Modeling the policy as rows (rather than hardcoded Ruby like PreAdmitValidator)
# is what lets new policies be added without code — the whole point of the slice.
class CoveragePolicy < ApplicationRecord
  has_many :criteria, -> { order(:position) },
           class_name: "PolicyCriterion", inverse_of: :coverage_policy, dependent: :destroy

  PAYERS       = %w[medicare].freeze          # slice 1 is Medicare-only
  SOURCE_TYPES = %w[lcd ncd].freeze

  validates :title, presence: true
  validates :payer,       inclusion: { in: PAYERS }
  validates :source_type, inclusion: { in: SOURCE_TYPES }

  scope :active, -> { where(active: true) }

  # The active policy governing a requested HCPCS procedure code, if any. This is
  # the "code -> governing policy" step of a review.
  def self.for_hcpcs(code)
    normalized = code.to_s.strip.upcase
    return nil if normalized.empty?
    active.where("? = ANY (procedure_hcpcs)", normalized).first
  end

  # "L34538 — Hospice Determining Terminal Status"
  def citation
    [ document_id.presence, title ].compact.join(" — ")
  end
end
