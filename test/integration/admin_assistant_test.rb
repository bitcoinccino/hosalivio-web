require "test_helper"

class AdminAssistantTest < ActionDispatch::IntegrationTest
  # Swap HosalivioBrain.complete_text for a fixed answer (or nil) for the block.
  def stubbing_brain(answer)
    original = HosalivioBrain.method(:complete_text)
    HosalivioBrain.define_singleton_method(:complete_text) { |**| answer }
    yield
  ensure
    HosalivioBrain.define_singleton_method(:complete_text, original)
  end

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
    post admin_assistant_ask_path, params: { q: "show today's pending items" }, as: :turbo_stream
    assert_response :success
    # chat exchange: the question appears as a bubble, then HosAlivio's answer
    assert_match "assistant-thread", response.body
    assert_match "show today", response.body                  # question bubble
    assert_match "priority items", response.body
    assert_match "NOE overdue", response.body
    assert_match "Maria Gonzalez", response.body
    # HosAlivio delivers the report in her voice (lead line + persona icon)
    assert_match "what I found", response.body
    assert_match "ri-sparkling-2-line", response.body
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
      post admin_assistant_ask_path, params: { q: query }, as: :turbo_stream
      assert_match title, response.body, "#{query.inspect} should route to #{title.inspect}"
    end
  end

  test "a free-form question gets a natural-language answer from HosAlivio" do
    sign_in @admin
    stubbing_brain("Everything is quiet today — no overdue NOEs.") do
      post admin_assistant_ask_path, params: { q: "hello, how are things looking?" }, as: :turbo_stream
    end
    assert_response :success
    assert_match "no overdue NOEs", response.body
    assert_no_match(/I didn't catch that/, response.body)
  end

  test "falls back to the command nudge when HosAlivio has no answer (no key)" do
    sign_in @admin
    stubbing_brain(nil) do
      post admin_assistant_ask_path, params: { q: "book a flight to Miami" }, as: :turbo_stream
    end
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
