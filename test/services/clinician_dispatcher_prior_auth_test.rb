require "test_helper"

# The "@HosAlivio start a prior auth" chat intent — offer → confirm, reusing the
# relay pattern.
class ClinicianDispatcherPriorAuthTest < ActiveSupport::TestCase
  setup do
    @agency   = create_agency
    @reviewer = create_user(agency: @agency, full_name: "Ivy Insurance", roles: %w[insurance])
    @patient  = in_tenant(@agency) { create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez") }
    @policy   = CoveragePolicy.create!(title: "Hospice LCD", payer: "medicare", source_type: "lcd",
                                       document_id: "L34538", procedure_hcpcs: %w[Q5001])
    @policy.criteria.create!(label: "PPS <= 70%", position: 0)
    @policy.criteria.create!(label: ">= 3 ADLs",  position: 1)
  end

  def note(body, author_role: "insurance")
    in_tenant(@agency) do
      Note.create!(agency: @agency, patient: @patient, author_role: author_role,
                   body: body, urgency: "normal", source: "text", clinician_only: true)
    end
  end

  def dispatch(body, requester: @reviewer, author_role: "insurance")
    msg = note(body, author_role: author_role)
    in_tenant(@agency) { ClinicianDispatcher.execute(note: msg, requester: requester, action: "start_prior_auth") }
  end

  def pending_offer
    in_tenant(@agency) { ClinicianDispatcher.pending_relay_offer(@patient) }
  end

  test "intent_for recognizes prior-auth phrasing, not passing mentions" do
    assert_equal "start_prior_auth", ClinicianDispatcher.intent_for("@HosAlivio start a prior auth for Q5001")
    assert_equal "start_prior_auth", ClinicianDispatcher.intent_for("run a prior authorization review please")
    assert_nil ClinicianDispatcher.intent_for("the prior auth came back approved yesterday")
  end

  test "a reviewer's request with a HCPCS code posts a Send/Cancel offer" do
    dispatch("@HosAlivio start a prior auth review for Q5001")
    offer = pending_offer
    assert offer, "an offer note was posted"
    assert_equal "prior_auth", offer.offer_payload["kind"]
    assert_equal "Q5001",      offer.offer_payload["procedure_hcpcs"]
  end

  test "no HCPCS in the message → a nudge with the form link, no offer" do
    dispatch("@HosAlivio start a prior auth review")
    assert_nil pending_offer, "no offer without a code"
    latest = in_tenant(@agency) { @patient.notes.order(:created_at).last }
    assert_match "procedure code", latest.body
    assert_match Rails.application.routes.url_helpers.new_prior_auth_review_path(patient_id: @patient.id), latest.body
  end

  test "a non-reviewer is told who can run it, no offer" do
    rn = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    dispatch("@HosAlivio start a prior auth for Q5001", requester: rn, author_role: "rn")
    assert_nil pending_offer
    latest = in_tenant(@agency) { @patient.notes.order(:created_at).last }
    assert_match(/admin, DON, MD, insurance, or billing/, latest.body)
  end

  test "confirming the offer runs the pipeline and creates a review" do
    dispatch("@HosAlivio start a prior auth for Q5001")
    offer = pending_offer

    assert_difference -> { in_tenant(@agency) { PriorAuthReview.count } }, 1 do
      in_tenant(@agency) { ClinicianDispatcher.execute(note: offer, requester: @reviewer, action: "confirm_relay") }
    end
    rev = in_tenant(@agency) { PriorAuthReview.order(:created_at).last }
    assert_equal "Q5001", rev.procedure_hcpcs
    assert_equal 2, rev.criterion_results.count   # one per policy criterion (LLM dormant → gaps)
  end

  test "cancelling the offer generates nothing" do
    dispatch("@HosAlivio start a prior auth for Q5001")
    offer = pending_offer
    assert_no_difference -> { in_tenant(@agency) { PriorAuthReview.count } } do
      in_tenant(@agency) { ClinicianDispatcher.execute(note: offer, requester: @reviewer, action: "cancel_relay") }
    end
  end
end
