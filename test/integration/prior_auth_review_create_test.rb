require "test_helper"

# The create-review entry point: pick a patient + procedure, run the pipeline.
class PriorAuthReviewCreateTest < ActionDispatch::IntegrationTest
  setup do
    @agency   = create_agency
    @reviewer = create_user(agency: @agency, full_name: "Ivy Insurance", roles: %w[insurance])
    @patient  = in_tenant(@agency) { create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez") }
    @policy   = CoveragePolicy.create!(title: "Hospice LCD", payer: "medicare", source_type: "lcd",
                                       document_id: "L34538", procedure_hcpcs: %w[Q5001])
    @policy.criteria.create!(label: "PPS <= 70%", position: 0)
    @policy.criteria.create!(label: ">= 3 ADLs",  position: 1)
  end

  test "new renders the full-page start form for a reviewer" do
    sign_in @reviewer
    get new_prior_auth_review_path(patient_id: @patient.id)
    assert_response :success
    assert_match "Start a Prior Authorization Review", response.body
    assert_match "Back to dashboard", response.body
    assert_no_match(/data-controller="modal"/, response.body)
  end

  test "new pre-fills the provider NPI from the patient's intake attending physician" do
    in_tenant(@agency) { @patient.update!(intake: { "attending_physician_npi" => "1578671483" }) }
    sign_in @reviewer
    get new_prior_auth_review_path(patient_id: @patient.id)
    assert_response :success
    assert_match "1578671483", response.body   # rendered into the NPI field value
  end

  test "new renders as a turbo-frame modal when requested from the quick action" do
    sign_in @reviewer
    get new_prior_auth_review_path(patient_id: @patient.id), headers: { "Turbo-Frame" => "pa-modal" }
    assert_response :success
    assert_match(/<turbo-frame[^>]*id="pa-modal"/, response.body)
    assert_match(/data-controller="modal"/, response.body)
    assert_match "Generate Review", response.body
    assert_match(/data-action="click->modal#close"[^>]*>Cancel/, response.body)  # non-destructive Cancel
    assert_no_match "Back to dashboard", response.body
  end

  test "create generates a review for a governed procedure and redirects to it" do
    sign_in @reviewer
    assert_difference -> { in_tenant(@agency) { PriorAuthReview.count } }, 1 do
      post prior_auth_reviews_path, params: {
        prior_auth_review: { patient_id: @patient.id, procedure_hcpcs: "q5001", provider_npi: "1578671483" }
      }
    end
    review = in_tenant(@agency) { PriorAuthReview.order(:created_at).last }
    assert_redirected_to prior_auth_review_path(review)
    assert_equal "Q5001", review.procedure_hcpcs
    assert_equal 2, review.criterion_results.count   # one per policy criterion
    assert review.recommendation_gap?                 # LLM dormant → nothing grounded
  end

  test "create re-renders with an alert when no policy governs the procedure" do
    sign_in @reviewer
    assert_no_difference -> { in_tenant(@agency) { PriorAuthReview.count } } do
      post prior_auth_reviews_path, params: {
        prior_auth_review: { patient_id: @patient.id, procedure_hcpcs: "99999" }
      }
    end
    assert_response :unprocessable_entity
    assert_match "No active Medicare coverage policy", response.body
  end

  test "a non-reviewer cannot open the start form" do
    rn = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    sign_in rn
    get new_prior_auth_review_path(patient_id: @patient.id)
    assert_redirected_to dashboard_path
  end
end
