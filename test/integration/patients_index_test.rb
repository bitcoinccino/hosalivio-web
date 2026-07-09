require "test_helper"

class PatientsIndexTest < ActionDispatch::IntegrationTest
  test "the roster lists patients, searches by name, and filters by status" do
    agency = create_agency
    admin  = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])
    maria  = create_patient(agency: agency, first_name: "Maria",  last_name: "Gonzalez")
    carlos = create_patient(agency: agency, first_name: "Carlos", last_name: "Diaz")
    in_tenant(agency) { maria.update!(status: :active); carlos.update!(status: :referred) }

    sign_in admin

    get patients_path
    assert_response :success
    assert_match "Maria Gonzalez", response.body
    assert_match "Carlos Diaz",    response.body
    assert_match "Register patient", response.body

    # Name search (deterministic-encrypted → filtered in Ruby).
    get patients_path(q: "maria")
    assert_response :success
    assert_match "Maria Gonzalez", response.body
    assert_no_match(/Carlos Diaz/,      response.body)

    # Status filter.
    get patients_path(status: "referred")
    assert_response :success
    assert_match "Carlos Diaz",    response.body
    assert_no_match(/Maria Gonzalez/,   response.body)
  end

  test "non-registrar roles are redirected away from the roster" do
    agency = create_agency
    rn     = create_user(agency: agency, full_name: "Reggie RN", roles: %w[rn])
    sign_in rn
    get patients_path
    assert_response :redirect
  end
end
