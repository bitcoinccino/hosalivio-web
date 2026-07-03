require "test_helper"

class PriorAuthReviewTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @patient = in_tenant(@agency) { create_patient(agency: @agency) }
    @policy  = CoveragePolicy.create!(title: "LCD", payer: "medicare", source_type: "lcd", document_id: "L34538")
    @c1 = @policy.criteria.create!(label: "PPS <= 70%", position: 0)
    @c2 = @policy.criteria.create!(label: ">= 3 ADLs",  position: 1)
  end

  R = PriorAuth::CriterionExtractor::Result

  def review
    in_tenant(@agency) do
      PriorAuthReview.create!(agency: @agency, patient: @patient, coverage_policy: @policy,
                              procedure_hcpcs: "Q5001", status: :draft)
    end
  end

  test "record_results persists a result per criterion and derives approve when all met" do
    results = [
      R.new(criterion_id: @c1.id, verdict: "met", verified: true,  evidence: { "doc_id" => "hp", "page" => 1, "quote" => "PPS 60" }, rationale: "ok"),
      R.new(criterion_id: @c2.id, verdict: "met", verified: true,  evidence: { "doc_id" => "hp", "page" => 1, "quote" => "3 ADLs" }, rationale: "ok")
    ]
    rev = in_tenant(@agency) { review.record_results(results) }

    assert_equal 2, rev.criterion_results.count
    assert rev.recommendation_approve?
    cr = rev.criterion_results.find_by(policy_criterion_id: @c1.id)
    assert cr.met?
    assert_equal "PPS 60", cr.evidence["quote"]   # accessor round-trips
  end

  test "any unmet/gap criterion derives a gap recommendation" do
    results = [
      R.new(criterion_id: @c1.id, verdict: "met",            verified: true,  evidence: { "quote" => "x" }, rationale: nil),
      R.new(criterion_id: @c2.id, verdict: "not_documented", verified: false, evidence: nil, rationale: nil)
    ]
    rev = in_tenant(@agency) { review.record_results(results) }
    assert rev.recommendation_gap?
    assert_equal 1, rev.gaps.size
    assert_equal @c2.id, rev.gaps.first.policy_criterion_id
  end

  test "record_results is idempotent (replaces prior results)" do
    rev = review
    in_tenant(@agency) do
      rev.record_results([ R.new(criterion_id: @c1.id, verdict: "met", verified: true, evidence: nil, rationale: nil) ])
      rev.record_results([ R.new(criterion_id: @c1.id, verdict: "unmet", verified: false, evidence: nil, rationale: nil) ])
    end
    assert_equal 1, rev.criterion_results.count
    assert rev.criterion_results.first.verdict_unmet?
  end

  test "a persisted 'met' that isn't verified is still treated as a gap" do
    cr = in_tenant(@agency) do
      r = review
      r.criterion_results.create!(policy_criterion: @c1, verdict: "met", verified: false)
    end
    assert_not cr.met?
    assert cr.gap?
  end

  test "evidence is encrypted at rest" do
    rev = in_tenant(@agency) do
      review.record_results([ R.new(criterion_id: @c1.id, verdict: "met", verified: true,
                                    evidence: { "quote" => "spiculated nodule RUL" }, rationale: nil) ])
    end
    id  = rev.criterion_results.first.id
    raw = CriterionResult.connection.select_value(
      "SELECT evidence_json FROM criterion_results WHERE id = #{CriterionResult.connection.quote(id)}"
    )
    refute_includes raw.to_s, "spiculated", "the stored evidence column must be ciphertext"
  end

  test "empty results derive a gap recommendation" do
    assert_equal :gap, in_tenant(@agency) { review.derive_recommendation }
  end
end
