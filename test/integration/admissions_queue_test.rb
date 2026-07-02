require "test_helper"

# The cross-patient admissions worklist.
class AdmissionsQueueTest < ActionDispatch::IntegrationTest
  setup do
    @agency = create_agency
    @rn     = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    @p1     = create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez")
    @p2     = create_patient(agency: @agency, first_name: "Sam",   last_name: "Lee")
  end

  def make_eval(patient:, status:)
    in_tenant(@agency) do
      PreAdmitEval.create!(agency: @agency, patient: patient, evaluator: @rn, evaluator_name: "Reggie RN",
        evaluated_at: Time.current, status: status, raw_json: { "pre_admit_eval" => {} })
    end
  end

  test "groups in-flight admission evals across patients by stage" do
    draft     = make_eval(patient: @p1, status: :draft)
    awaiting  = make_eval(patient: @p2, status: :final)

    sign_in @rn
    get admissions_queue_path

    assert_response :success
    assert_match(/Awaiting MD certification/, response.body)
    assert_match "Maria Gonzalez", response.body
    assert_match "Sam Lee", response.body
    assert_select "a[href=?]", pre_admit_eval_path(draft)
    assert_select "a[href=?]", pre_admit_eval_path(awaiting)
  end

  test "shows an all-caught-up state with no in-flight evals" do
    make_eval(patient: @p1, status: :noe_filed) # completed, not in-flight
    sign_in @rn
    get admissions_queue_path
    assert_response :success
    assert_match(/all caught up/i, response.body)
  end

  test "a family user cannot view the queue" do
    fam = create_user(agency: @agency, full_name: "Fam", family_access: true, patient: @p1)
    sign_in fam
    get admissions_queue_path
    assert_redirected_to welcome_path
  end
end
