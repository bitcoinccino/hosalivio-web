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
    assert_no_match(/Maria Gonzalez/, response.body)

    # Per-patient record line (pre-admit eval · team notes · documents).
    get patients_path
    assert_match "No eval",  response.body   # neither patient has an eval yet
    assert_match "notes",    response.body   # team-note count
    assert_match "docs",     response.body   # documents-with-type count
  end

  test "the roster filters by branch" do
    agency = create_agency
    admin  = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])
    maria  = create_patient(agency: agency, first_name: "Maria",  last_name: "Gonzalez")
    create_patient(agency: agency, first_name: "Carlos", last_name: "Diaz")
    branch = in_tenant(agency) do
      b = Branch.create!(agency: agency, name: "Hialeah", timezone: "America/New_York", active: true)
      maria.update!(branch: b)
      b
    end

    sign_in admin
    get patients_path
    assert_match "All branches", response.body   # the branch filter select
    assert_match "Hialeah",      response.body

    get patients_path(branch_id: branch.id)
    assert_response :success
    assert_match "Maria Gonzalez", response.body
    assert_no_match(/Carlos Diaz/,      response.body)
  end

  test "non-registrar roles are redirected away from the roster" do
    agency = create_agency
    rn     = create_user(agency: agency, full_name: "Reggie RN", roles: %w[rn])
    sign_in rn
    get patients_path
    assert_response :redirect
  end
end
