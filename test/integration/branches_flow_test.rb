require "test_helper"

class BranchesFlowTest < ActionDispatch::IntegrationTest
  setup do
    @agency = create_agency
    @admin  = create_user(agency: @agency, full_name: "Ada Admin", roles: %w[admin])
    @branch = in_tenant(@agency) { Branch.create!(agency: @agency, name: "Orlando", timezone: "America/New_York") }
  end

  test "the edit form renders the ZIP tag input" do
    in_tenant(@agency) { @branch.update!(service_area_zips: %w[328 32801]) }
    sign_in @admin
    get edit_branch_path(@branch)
    assert_response :success
    assert_match 'data-controller="tag-input"', response.body
    assert_match "32801", response.body
  end

  test "updating ZIP tags via array params stores a clean array" do
    sign_in @admin
    patch branch_path(@branch), params: { branch: { service_area_zips: [ "", "328", "32801", "32801" ] } }
    assert_equal %w[328 32801], @branch.reload.service_area_zips
  end

  test "clearing every ZIP tag empties the array" do
    in_tenant(@agency) { @branch.update!(service_area_zips: %w[328 32801]) }
    sign_in @admin
    patch branch_path(@branch), params: { branch: { service_area_zips: [ "" ] } }
    assert_empty @branch.reload.service_area_zips
  end
end
