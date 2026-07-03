require "test_helper"

# The coordination queue — inbound leads + new registrations side by side.
class CoordinationQueueTest < ActionDispatch::IntegrationTest
  setup do
    @agency = create_agency
    @coord  = create_user(agency: @agency, full_name: "Cara Coord", roles: %w[admissions])
  end

  test "shows open leads and newly-registered patients, not converted/admitted ones" do
    lead = in_tenant(@agency) do
      Inquiry.create!(agency: @agency, first_name: "Lena", contact: "305-555-0100", zip: "33101",
                      source_prompt: "fhir_referral", status: :new_lead)
    end
    converted = in_tenant(@agency) do
      Inquiry.create!(agency: @agency, first_name: "Gone", contact: "x@y.com", zip: "33101",
                      source_prompt: "capture", status: :converted)
    end
    new_pt = in_tenant(@agency) { create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez") } # referred by default
    active = in_tenant(@agency) { create_patient(agency: @agency, first_name: "Al", last_name: "Ready") }
    in_tenant(@agency) { active.update_column(:status, Patient.statuses[:active]) }

    sign_in @coord
    get coordination_path

    assert_response :success
    assert_match "Coordination queue", response.body
    assert_select "a[href=?]", convert_inquiry_path(lead)          # open lead → convert
    assert_no_match(/#{convert_inquiry_path(converted)}/, response.body) # converted lead excluded
    assert_match "Maria Gonzalez", response.body                    # referred patient shown
    assert_select "a[href=?]", edit_patient_path(new_pt)           # verify-insurance link
    assert_select "a[href=?]", new_visit_path(patient_id: new_pt.id)
    assert_no_match "Al Ready", response.body                       # active patient excluded
  end

  test "a non-coordinator is redirected" do
    rn = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    sign_in rn
    get coordination_path
    assert_redirected_to dashboard_path
  end
end
