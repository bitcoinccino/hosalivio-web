require "test_helper"

class AdminAssistantTest < ActionDispatch::IntegrationTest
  setup do
    @agency = create_agency
    @admin  = create_user(agency: @agency, full_name: "Ada Admin", roles: %w[admin])
  end

  test "a manager gets today's priority items, agency-scoped" do
    rn      = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    patient = in_tenant(@agency) { create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez") }
    in_tenant(@agency) do
      PreAdmitEval.create!(agency: @agency, patient: patient, evaluator: rn, evaluator_name: "Reggie RN",
                           status: :certified, noe_deadline_at: 2.days.ago, raw_json: { "pre_admit_eval" => {} })
    end

    sign_in @admin
    post admin_assistant_ask_path, params: { q: "show today's pending items" }
    assert_response :success
    assert_match "priority items", response.body
    assert_match "NOE overdue", response.body
    assert_match "Maria Gonzalez", response.body
  end

  test "the classifier routes each command to its answer title" do
    sign_in @admin
    {
      # exact phrases the dashboard quick-ask buttons submit
      "today's priorities"           => "priority items",
      "patients needing attention"   => "Patients needing attention",
      "compliance status"            => "Compliance status",
      "new referrals"                => "New referrals",
      "daily report"                 => "Daily report"
    }.each do |query, title|
      post admin_assistant_ask_path, params: { q: query }
      assert_match title, response.body, "#{query.inspect} should route to #{title.inspect}"
    end
  end

  test "an unrecognized command gets a graceful nudge listing the commands" do
    sign_in @admin
    post admin_assistant_ask_path, params: { q: "book a flight to Miami" }
    assert_response :success
    assert_match "I didn't catch that", response.body
    assert_match "compliance status", response.body
  end

  test "a non-manager is redirected" do
    rn = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    sign_in rn
    post admin_assistant_ask_path, params: { q: "show today's pending items" }
    assert_redirected_to dashboard_path
  end
end
