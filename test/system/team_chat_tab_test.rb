require "application_system_test_case"

class TeamChatTabTest < ApplicationSystemTestCase
  test "clicking the Team chat tab reveals the channel thread + composer" do
    agency = create_agency
    admin  = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])

    in_tenant(agency) do
      Channel.ensure_defaults_for(agency)
      general = Channel.find_by!(slug: "general")
      general.channel_messages.create!(agency: agency, user: admin, body: "HELLO-TEAM-CHAT-MARKER")
    end

    sign_in_as(admin)
    visit dashboard_path

    # The right rail defaults to Live activity; Team chat pane starts hidden.
    assert_selector "aside button", text: /team chat/i

    # Regression: Pane 0 (activity) once dropped its closing </div>, nesting the
    # Team-chat pane inside it — so clicking the tab un-hid a pane whose hidden
    # ancestor kept it invisible. Clicking must now actually reveal the thread.
    find("aside button", text: /team chat/i, match: :first).click

    assert_selector "input[placeholder*='Message #general']", visible: true, wait: 3
    assert_text "HELLO-TEAM-CHAT-MARKER"
  end

  test "older-day messages collapse behind a Show earlier messages toggle" do
    agency = create_agency
    admin  = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])

    in_tenant(agency) do
      Channel.ensure_defaults_for(agency)
      general = Channel.find_by!(slug: "general")
      old = general.channel_messages.create!(agency: agency, user: admin, body: "OLD-DAY-MESSAGE")
      old.update_column(:created_at, 2.days.ago)
      general.channel_messages.create!(agency: agency, user: admin, body: "TODAY-MESSAGE")
    end

    sign_in_as(admin)
    visit dashboard_path
    find("aside button", text: /team chat/i, match: :first).click

    # Latest day shows; the older message is tucked behind the toggle (hidden).
    assert_text "TODAY-MESSAGE"
    assert_selector "summary", text: /show earlier messages/i
    assert_no_text "OLD-DAY-MESSAGE"

    # Opening the toggle reveals it.
    find("summary", text: /show earlier messages/i).click
    assert_text "OLD-DAY-MESSAGE"
  end
end
