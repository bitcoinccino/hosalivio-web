# One criterion's outcome within a PriorAuthReview — the persisted form of a
# CriterionExtractor::Result. Reachable only through its (tenant-scoped) review.
# The cited evidence is PHI, so it's stored as an encrypted JSON blob.
class CriterionResult < ApplicationRecord
  belongs_to :prior_auth_review
  belongs_to :policy_criterion

  encrypts :evidence_json

  enum :verdict, { met: 0, unmet: 1, not_documented: 2, uncertain: 3 }, prefix: true

  # Grounded pass: the model said met AND Stage 3 verified the quote. A "met"
  # that isn't verified never reaches here (the extractor downgrades it), but the
  # verified check keeps this honest regardless.
  def met? = verdict_met? && verified

  def gap? = !met?

  # Parsed evidence hash ({ "doc_id", "page", "quote" }), or nil.
  def evidence
    JSON.parse(evidence_json) if evidence_json.present?
  rescue JSON::ParserError
    nil
  end

  def evidence=(hash)
    self.evidence_json = hash.present? ? hash.to_json : nil
  end
end
