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
    # HosAlivio's answer is appended to the chat thread (the question bubble +
    # typing indicator are added client-side, so they're not in this response).
    assert_match "assistant-thread", response.body
    assert_match "priority items", response.body
    assert_match "NOE overdue", response.body
    assert_match "Maria Gonzalez", response.body
    # HosAlivio delivers the report in her voice (single lead + persona icon)
    assert_match "2 items", response.body
    assert_match "ri-sparkling-2-line", response.body
  end

  test "a status report with all-zero metrics reads as a status snapshot, not findings" do
    sign_in @admin
    # No pending evals → compliance metrics are all zero.
    post admin_assistant_ask_path, params: { q: "compliance status" }, as: :turbo_stream
    assert_response :success
    assert_match "all clear right now", response.body
    assert_no_match(/what I found/, response.body)   # zeros aren't "findings"
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
      # topic is folded into the lead (lowercased for findings reports), so match case-insensitively
      assert_match(/#{Regexp.escape(title)}/i, response.body, "#{query.inspect} should route to #{title.inspect}")
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

  test "the agency snapshot feeds the LLM an active-patient headcount" do
    in_tenant(@agency) do
      create_patient(agency: @agency, first_name: "Ann", last_name: "A").update!(status: :active)
      create_patient(agency: @agency, first_name: "Ben", last_name: "B").update!(status: :active)
      Branch.create!(agency: @agency, name: "Orlando", timezone: "America/New_York")
    end
    sign_in @admin
    # Echo the prompt back as the "answer" so we can assert what the model saw.
    original = HosalivioBrain.method(:complete_text)
    HosalivioBrain.define_singleton_method(:complete_text) { |system:, user:| user }
    begin
      post admin_assistant_ask_path, params: { q: "how many active patients do we have?" }, as: :turbo_stream
    ensure
      HosalivioBrain.define_singleton_method(:complete_text, original)
    end
    assert_response :success
    assert_match "Census:", response.body
    assert_match "2 active patients", response.body
    # the snapshot spans the admin-relevant models, not just the reports
    assert_match "Staff:", response.body
    assert_match "active staff", response.body
    assert_match(/Agency: /, response.body)
    assert_match "snapshot as of", response.body        # last-updated timestamp
    assert_match "Branches — 1 active", response.body   # branch rollup header
  end

  test "greets warmly even with no LLM (canned reply, not the nudge)" do
    sign_in @admin
    stubbing_brain(nil) do
      post admin_assistant_ask_path, params: { q: "hello" }, as: :turbo_stream
    end
    assert_response :success
    assert_match "Ask me for", response.body            # the warm greeting reply
    assert_no_match(/I didn't catch that/, response.body)
  end

  test "falls back to the command nudge for unknown input with no LLM" do
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
