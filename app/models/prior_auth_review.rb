# A prior-authorization / medical-necessity review for one requested procedure
# (see docs/prior-auth-slice.md). Tenant-scoped (unlike the shared CoveragePolicy
# reference). Holds the per-criterion results and a drafted recommendation; a
# human reviewer signs off before it's final.
class PriorAuthReview < ApplicationRecord
  acts_as_tenant :agency

  belongs_to :agency
  belongs_to :patient
  belongs_to :coverage_policy
  belongs_to :reviewed_by, class_name: "User", optional: true

  has_many :criterion_results, dependent: :destroy

  encrypts :recommendation_note

  enum :status,         { draft: 0, reviewed: 1, signed: 2 }, prefix: true
  enum :recommendation, { pending: 0, approve: 1, gap: 2, deny: 3 }, prefix: true

  # Persist a set of CriterionExtractor::Result structs as criterion_results and
  # (re)derive the recommendation. Idempotent — replaces prior results.
  def record_results(results)
    transaction do
      criterion_results.destroy_all
      Array(results).each do |r|
        criterion_results.create!(
          policy_criterion_id: r.criterion_id,
          verdict:             r.verdict,
          verified:            r.verified,
          evidence:            r.evidence,
          rationale:           r.rationale
        )
      end
      update!(recommendation: derive_recommendation)
    end
    self
  end

  # Auto-suggestion only — the reviewer confirms/overrides. Every criterion met
  # (and grounded) → approve; anything short → gap. "deny" is a human decision.
  def derive_recommendation
    return :gap if criterion_results.empty?
    criterion_results.all?(&:met?) ? :approve : :gap
  end

  # The criteria still standing in the way (drives the gap list in the UI).
  def gaps
    criterion_results.select(&:gap?)
  end
end
