require "test_helper"

# RN reviews and accepts the intake fields an admission visit surfaced.
class VisitIntakeSuggestionsTest < ActionDispatch::IntegrationTest
  setup do
    @agency = create_agency
    @rn = create_user(agency: @agency, full_name: "Rita RN", roles: %w[rn])
  end

  def visit_with_suggestions(suggestions)
    in_tenant(@agency) do
      patient = create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez")
      visit = Visit.create!(agency: @agency, patient: patient, user: @rn,
                            visit_type: "admission", discipline: "rn", scheduled_at: Time.current)
      visit.update!(suggested_intake: suggestions)
      [ visit, patient ]
    end
  end

  test "applying only the checked suggestions writes blanks-only and clears staging" do
    visit, patient = visit_with_suggestions(
      "marital_status" => "Widowed", "veteran_status" => "Veteran",
      "caregiver_relationship" => "Daughter", "code_status" => "dnr"
    )

    sign_in @rn
    post apply_intake_suggestions_visit_path(visit), params: { fields: %w[marital_status code_status] }

    patient.reload
    assert_equal "Widowed", patient.intake["marital_status"]  # intake blob key
    assert_equal "dnr",     patient.code_status               # Patient column
    assert patient.veteran_status.blank?,        "unchecked field not written"
    assert patient.caregiver_relationship.blank?, "unchecked field not written"
    assert visit.reload.suggested_intake.empty?, "staging blob cleared after apply"
  end

  test "a field the patient already filled is not overwritten even if checked" do
    visit, patient = visit_with_suggestions("marital_status" => "Widowed")
    in_tenant(@agency) { patient.update!(intake: { "marital_status" => "Married" }) }

    sign_in @rn
    post apply_intake_suggestions_visit_path(visit), params: { fields: %w[marital_status] }

    assert_equal "Married", patient.reload.intake["marital_status"], "registration value preserved"
  end

  test "dismiss clears staging without writing anything" do
    visit, patient = visit_with_suggestions("marital_status" => "Widowed")

    sign_in @rn
    post dismiss_intake_suggestions_visit_path(visit)

    assert visit.reload.suggested_intake.empty?
    assert patient.reload.intake["marital_status"].blank?
  end
end
