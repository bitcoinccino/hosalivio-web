require "test_helper"

# The per-patient admission-eval history list.
class PatientAdmissionsTest < ActionDispatch::IntegrationTest
  setup do
    @agency  = create_agency
    @rn      = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    @patient = create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez")
  end

  def make_eval(status:, icd10: nil)
    in_tenant(@agency) do
      PreAdmitEval.create!(
        agency: @agency, patient: @patient, evaluator: @rn, evaluator_name: "Reggie RN",
        evaluated_at: Time.current, status: status,
        raw_json: { "pre_admit_eval" => (icd10 ? { "diagnosis" => { "primary_terminal_diagnosis" => { "icd10" => icd10, "description" => "Malignant neoplasm of lung" } } } : {}) }
      )
    end
  end

  test "lists a patient's admission evals newest-first with a link to each" do
    older  = make_eval(status: :certified, icd10: "C34.90")
    newer  = make_eval(status: :draft)
    in_tenant(@agency) { older.update_column(:created_at, 2.days.ago) }

    sign_in @rn
    get patient_admissions_path(@patient)

    assert_response :success
    assert_select "h1", /Maria Gonzalez/
    assert_select "a[href=?]", pre_admit_eval_path(newer)
    assert_select "a[href=?]", pre_admit_eval_path(older)
    assert_match "Malignant neoplasm of lung", response.body
    assert_match(/2 admission evals/, response.body)
  end

  test "shows an empty state when the patient has no evals" do
    sign_in @rn
    get patient_admissions_path(@patient)
    assert_response :success
    assert_match(/No admission evals on file/, response.body)
  end

  test "a family user cannot view the admissions list" do
    fam = create_user(agency: @agency, full_name: "Fam", family_access: true, patient: @patient)
    sign_in fam
    get patient_admissions_path(@patient)
    assert_redirected_to welcome_path
  end
end
