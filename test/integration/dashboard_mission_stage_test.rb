require "test_helper"

class DashboardMissionStageTest < ActionDispatch::IntegrationTest
  test "the manager (Mission Stage) dashboard renders with the quick-stats bar + tidied sidebar" do
    agency = create_agency
    admin  = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])

    sign_in admin
    get dashboard_path

    assert_response :success
    assert_match "Mission Stage", response.body
    # quick-stats bar
    assert_match "Active patients", response.body
    assert_match "Pending reviews", response.body
    assert_match "Open blockers", response.body
    assert_match "NOE deadlines", response.body
    # sidebar tidy
    assert_match "Admissions queue", response.body
    assert_match "Reports", response.body
    # ask assistant composer still present
    assert_match "Ask HosAlivio", response.body
    # patient-chat-style layout: banner status line, left census, right feed
    assert_match "Care Team", response.body          # banner status line
    assert_match "Active Census", response.body      # left-rail census list
    assert_match "Live agent activity", response.body # right-rail feed header
    # mobile bottom tab bar
    assert_match "Activity", response.body
    assert_match "Stage", response.body
  end
end
