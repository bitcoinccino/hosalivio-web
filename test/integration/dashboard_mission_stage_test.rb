require "test_helper"

class DashboardMissionStageTest < ActionDispatch::IntegrationTest
  test "the manager (Mission Stage) dashboard renders with the quick-stats bar + tidied sidebar" do
    agency = create_agency
    admin  = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])
    create_user(agency: agency, full_name: "Reggie RN", roles: %w[rn])

    sign_in admin
    get dashboard_path

    assert_response :success
    assert_match "Mission Stage", response.body
    # nothing pending → the "At a glance" panel stays hidden (no empty-state filler)
    assert_no_match(/At a glance/, response.body)
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
    assert_match "Live activity", response.body # right-rail feed header
    # mobile bottom tab bar
    assert_match "Activity", response.body
    assert_match "Stage", response.body
    # team chat moved into the composer's "+" modal, with flip-to-channel wiring
    assert_match "Team channels", response.body
    assert_match "general", response.body
    assert_match "admission", response.body
    assert_match "composer", response.body
    assert_match "composer#channel", response.body
    assert_match channel_messages_path("general"), response.body
    # popover-style menu (like the patient composer) with channel blurbs
    assert_match "data-quick-actions-target", response.body
    assert_match "Team announcements and general discussion", response.body
    assert_match "Referrals, pre-admit evals, blockers, and scheduling.", response.body
    # @-mention autocomplete in the composer, pooled with agency staff
    assert_match "mention-autocomplete", response.body
    assert_match "data-mention-autocomplete-target", response.body
    assert_match "Reggie", response.body   # the RN is in the mention pool JSON
    # one-tap oversight quick-ask buttons above the composer (hidden in team-chat mode)
    assert_match 'data-composer-target="quickAsks"', response.body
    assert_match "Today&#39;s priorities", response.body
    assert_match "Patients needing attention", response.body
    assert_match "Compliance status", response.body
    assert_match "Daily report", response.body
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
    # type-category lanes: filter chips + per-bubble category tag
    assert_match "data-lane-chip", response.body
    assert_match "Admissions", response.body
    assert_match "Clinical", response.body
    assert_match 'data-category="admissions"', response.body
  end
end
