require "test_helper"

# Stage 5 — the reviewer opens a grounded determination and signs off.
class PriorAuthReviewFlowTest < ActionDispatch::IntegrationTest
  R = PriorAuth::CriterionExtractor::Result

  setup do
    @agency   = create_agency
    @reviewer = create_user(agency: @agency, full_name: "Ivy Insurance", roles: %w[insurance])
    @patient  = in_tenant(@agency) { create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez") }
    @policy   = CoveragePolicy.create!(title: "Hospice LCD", payer: "medicare", source_type: "lcd", document_id: "L34538")
    @c1 = @policy.criteria.create!(label: "PPS <= 70%", position: 0)
    @c2 = @policy.criteria.create!(label: ">= 3 ADLs",  position: 1)

    @review = in_tenant(@agency) do
      rev = PriorAuthReview.create!(agency: @agency, patient: @patient, coverage_policy: @policy,
                                    procedure_hcpcs: "Q5001", status: :draft)
      rev.record_results([
        R.new(criterion_id: @c1.id, verdict: "met", verified: true,  evidence: { "doc_id" => "d1", "page" => 2, "quote" => "PPS is 60 percent" }, rationale: "PPS 60"),
        R.new(criterion_id: @c2.id, verdict: "not_documented", verified: false, evidence: nil, rationale: nil)
      ])
    end
  end

  test "a reviewer sees the determination, criteria, verified evidence, and the gap" do
    sign_in @reviewer
    get prior_auth_review_path(@review)

    assert_response :success
    assert_match "Prior-authorization review", response.body
    assert_match "L34538", response.body
    assert_match "PPS &lt;= 70%", response.body
    assert_match "PPS is 60 percent", response.body        # verified evidence quote
    assert_match "Gaps to resolve", response.body           # derived recommendation (one gap)
  end

  test "signing off applies a signature, sets reviewer + recommendation + status" do
    sign_in @reviewer
    assert_difference -> { Signature.where(signable_type: "PriorAuthReview").count }, 1 do
      post sign_off_prior_auth_review_path(@review), params: { recommendation: "deny" }
    end

    @review.reload
    assert @review.status_signed?
    assert @review.recommendation_deny?, "reviewer override is honored"
    assert_equal @reviewer.id, @review.reviewed_by_id
    assert AgentEvent.exists?(subject: @review, action: "prior_auth_signoff")
  end

  test "an MD can review" do
    md = create_user(agency: @agency, full_name: "Dr. Mona MD", roles: %w[md])
    sign_in md
    get prior_auth_review_path(@review)
    assert_response :success
  end

  test "a non-reviewer clinician is blocked" do
    rn = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    sign_in rn
    get prior_auth_review_path(@review)
    assert_redirected_to dashboard_path
  end
end
