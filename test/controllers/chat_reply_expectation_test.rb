require "test_helper"

# The chat UI keeps its "HosAlivio is thinking" indicator up only while a reply
# is actually coming. The send endpoints expose ai_reply_expected so the client
# can drop the dots immediately for messages that get no AI reply (instead of
# hanging 90s and force-reloading the page).
class ChatReplyExpectationTest < ActionDispatch::IntegrationTest
  setup do
    @agency  = create_agency
    @rn      = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    @patient = create_patient(agency: @agency)
  end

  test "a clinical top-level note expects an AI reply (it gets acted on)" do
    sign_in @rn
    post "/api/v1/clinician_messages",
         params: { patient_id: @patient.id, text: "Patient resting comfortably, no concerns.", source: "text" },
         as: :json
    assert_response :created
    assert_equal true, response.parsed_body["ai_reply_expected"]
  end

  test "an @HosAlivio thread reply expects an AI reply" do
    parent = in_tenant(@agency) do
      Note.create!(agency: @agency, patient: @patient, author_user: @rn, author_role: "rn",
                   body: "Team huddle note", source: "text", clinician_only: true, urgency: "normal")
    end
    sign_in @rn
    post "/api/v1/clinician_messages",
         params: { patient_id: @patient.id, parent_note_id: parent.id,
                   text: "@HosAlivio can you summarize her week?", source: "text" },
         as: :json
    assert_response :created
    assert_equal true, response.parsed_body["ai_reply_expected"]
  end

  test "a plain clinician thread reply expects no AI reply" do
    parent = in_tenant(@agency) do
      Note.create!(agency: @agency, patient: @patient, author_user: @rn, author_role: "rn",
                   body: "Team huddle note", source: "text", clinician_only: true, urgency: "normal")
    end
    sign_in @rn
    post "/api/v1/clinician_messages",
         params: { patient_id: @patient.id, parent_note_id: parent.id, text: "Thanks, noted.", source: "text" },
         as: :json
    assert_response :created
    assert_equal false, response.parsed_body["ai_reply_expected"]
  end

  test "a family message always expects an AI reply" do
    fam = create_user(agency: @agency, full_name: "Fam Member", family_access: true, patient: @patient)
    sign_in fam
    post "/api/v1/family_messages",
         params: { patient_id: @patient.id, text: "How is she doing today?", source: "text" },
         as: :json
    assert_response :created
    assert_equal true, response.parsed_body["ai_reply_expected"]
  end
end
