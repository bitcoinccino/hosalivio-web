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

  test "the activity feed groups by day with a Show earlier messages toggle" do
    agency = create_agency
    admin  = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])

    in_tenant(agency) do
      AgentEvent.create!(agency: agency, agent_id: "admissions", action: "create", subject_type: "Patient", happened_at: 3.days.ago)
      AgentEvent.create!(agency: agency, agent_id: "admissions", action: "create", subject_type: "Patient", happened_at: Time.current)
    end

    sign_in admin
    get dashboard_path

    assert_response :success
    # Older-than-today activity collapses behind the toggle...
    assert_match "Show earlier messages", response.body
    # ...and the latest day is tagged so live inserts can find it.
    assert_match "data-today-divider", response.body
    assert_match "Today", response.body
  end
end
