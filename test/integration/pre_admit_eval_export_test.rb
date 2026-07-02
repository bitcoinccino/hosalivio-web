require "test_helper"

# A clinician can export a finalized admission eval as a schema-valid FHIR
# document (no EMR gateway credentials needed).
class PreAdmitEvalExportTest < ActionDispatch::IntegrationTest
  setup do
    @agency  = create_agency
    @rn      = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    @patient = create_patient(agency: @agency)
    @eval    = in_tenant(@agency) do
      PreAdmitEval.create!(
        agency: @agency, patient: @patient, evaluator: @rn,
        evaluator_name: "Reggie RN", evaluated_at: Time.current, status: :final,
        raw_json: { "pre_admit_eval" => {
          "diagnosis" => { "primary_terminal_diagnosis" => { "icd10" => "C34.90", "description" => "Malignant neoplasm of lung" } }
        } }
      )
    end
  end

  test "a nurse exports a finalized eval as a FHIR bundle" do
    sign_in @rn
    get export_fhir_pre_admit_eval_path(@eval)

    assert_response :success
    assert_equal "application/fhir+json", response.media_type
    assert_match(/attachment/, response.headers["Content-Disposition"])

    body = JSON.parse(response.body)
    assert_equal "Bundle", body["resourceType"]
    condition = body["entry"].map { |e| e["resource"] }.find { |r| r["resourceType"] == "Condition" }
    assert_equal "C34.90", condition.dig("code", "coding", 0, "code")
  end

  test "exporting writes an AgentEvent audit record" do
    sign_in @rn
    assert_difference -> { in_tenant(@agency) { AgentEvent.where(action: "eval_fhir_exported").count } }, 1 do
      get export_fhir_pre_admit_eval_path(@eval)
    end
    ev = in_tenant(@agency) { AgentEvent.where(action: "eval_fhir_exported").last }
    assert_equal @eval.id,   ev.subject_id
    assert_equal "Reggie RN", ev.change_set["exported_by"]
    assert_equal "rn",        ev.change_set["exported_by_role"]
  end

  test "a draft eval cannot be exported yet" do
    in_tenant(@agency) { @eval.update_column(:status, PreAdmitEval.statuses[:draft]) }
    sign_in @rn
    get export_fhir_pre_admit_eval_path(@eval)

    assert_redirected_to pre_admit_eval_path(@eval)
    assert_match(/Finalize/, flash[:alert])
  end

  test "a family user cannot export" do
    fam = create_user(agency: @agency, full_name: "Fam Member", family_access: true, patient: @patient)
    sign_in fam
    get export_fhir_pre_admit_eval_path(@eval)
    assert_redirected_to welcome_path
  end
end
