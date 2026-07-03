require "test_helper"

# The admission intake form: core Patient columns + the encrypted intake blob.
class PatientIntakeTest < ActionDispatch::IntegrationTest
  setup do
    @agency = create_agency
    @coord  = create_user(agency: @agency, full_name: "Cara Coord", roles: %w[admissions])
  end

  test "registering a patient persists core fields and the allowlisted intake blob" do
    sign_in @coord
    assert_difference -> { ActsAsTenant.with_tenant(@agency) { Patient.count } }, 1 do
      post patients_path, params: {
        patient: {
          first_name: "Maria", last_name: "Gonzalez", dob: "1940-03-02", gender: "Female",
          intake: {
            marital_status: "Widowed", race: "White",
            attending_physician_name: "Dr. Smith", attending_physician_npi: "1578671483",
            veteran_active_duty: "no", insurance_medicare_status: "active",
            billing_contact_name: "Daughter", not_a_real_key: "x"
          }
        }
      }
    end

    p = ActsAsTenant.with_tenant(@agency) { Patient.order(:created_at).last }
    assert_equal "Maria",     p.first_name
    assert_equal "Widowed",   p.intake["marital_status"]
    assert_equal "Dr. Smith", p.intake["attending_physician_name"]
    assert_equal "active",    p.intake["insurance_medicare_status"]
    assert_not p.intake.key?("not_a_real_key"), "the allowlist drops unknown keys"
  end

  test "editing merges into the existing intake blob" do
    p = in_tenant(@agency) do
      Patient.create!(agency: @agency, first_name: "Sam", last_name: "Lee", dob: Date.new(1950, 1, 1),
                      mrn: "MX2", intake: { "marital_status" => "Married" })
    end
    sign_in @coord
    patch patient_path(p), params: { patient: { first_name: "Sam", last_name: "Lee", intake: { race: "Asian" } } }

    p.reload
    assert_equal "Asian",   p.intake["race"]
    assert_equal "Married", p.intake["marital_status"], "merge preserves existing intake keys"
  end

  test "the intake form renders for editing an existing patient" do
    p = in_tenant(@agency) { create_patient(agency: @agency) }
    sign_in @coord
    get edit_patient_path(p)
    assert_response :success
    assert_match "Patient intake", response.body
    assert_select "form"
  end

  test "a non-registrar clinician is blocked from the intake form" do
    rn = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    sign_in rn
    get new_patient_path
    assert_response :redirect
  end
end
