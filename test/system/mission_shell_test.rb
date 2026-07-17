require "application_system_test_case"

# Real-browser coverage for the two things request tests can't see: that the
# feed row actually reads actor-first, and that the nav shell is usable on a
# phone. Integration tests only prove Tailwind classes are in the HTML — they
# can't tell you the drawer opens or that a table fits at 375px.
class MissionShellTest < ApplicationSystemTestCase
  DESKTOP = [ 1400, 1000 ].freeze
  PHONE   = [ 375, 812 ].freeze   # iPhone X

  setup do
    # Selenium reuses ONE browser for the entire run, and window size is global
    # to it. A phone-sized window left behind here leaks into every test that
    # follows — including other classes — silently hiding anything behind `md:`.
    # (This bit TeamChatTabTest: it inherited 375px and its right-rail aside
    # was hidden, so it failed intermittently depending on test order.)
    # Belt and braces: reset on the way in AND on the way out, since an error
    # can skip teardown.
    resize_to_desktop

    @agency  = create_agency
    @admin   = create_user(agency: @agency, full_name: "Ada Admin", roles: %w[admin])
    @patient = create_patient(agency: @agency, first_name: "Benworth", last_name: "Zoff")
  end

  teardown { resize_to_desktop }

  def resize_to_desktop = page.driver.browser.manage.window.resize_to(*DESKTOP)
  def resize_to_phone   = page.driver.browser.manage.window.resize_to(*PHONE)

  # A family-triage note + the AgentEvent the feed narrates from — the exact
  # shape HosalivioTriager writes.
  def triage_note!(body: "Is the new dose safe?")
    in_tenant(@agency) do
      note = Note.create!(agency: @agency, patient: @patient, author_role: "admissions",
                          body: body, urgency: "normal", source: "system", clinician_only: true)
      AgentEvent.create!(agency: @agency, agent_id: "triage",
                         agent_session_id: "hosalivio-claude-#{SecureRandom.hex(4)}",
                         action: "create", subject: note, happened_at: Time.current)
      note
    end
  end

  test "a feed row names HosAlivio as the actor, not the patient" do
    triage_note!
    sign_in_as(@admin)
    visit dashboard_path

    row = find("[data-story]", match: :first)

    # The headline is the actor. Before this change it was "Benworth Zoff",
    # which read as though the patient triaged his own family's message.
    assert_equal "HosAlivio (Triage)", row.first("div.font-semibold").text
    assert_text "triaged a family message"

    # The patient is still on the row — just on the meta line, not the headline.
    assert_match(/Benworth Zoff/, row.text)

    # HosAlivio wears the AI mark; the avatar carries no initials.
    assert row.has_css?("i.ri-sparkling-2-line"), "HosAlivio should wear the AI icon"
  end

  test "a feed row deep-links to the note, not just the chart" do
    note = triage_note!
    sign_in_as(@admin)
    visit dashboard_path

    href = find("a[data-story]", match: :first)[:href]
    assert_includes href, "note=#{note.id}", "row should deep-link to the note it is about"
  end

  test "the persona map reaches the browser without throwing" do
    sign_in_as(@admin)
    visit dashboard_path
    # _feed_constants must define window.HosAlivioFeed BEFORE the feed script
    # destructures it — otherwise the script dies and the feed silently stops.
    assert_equal 17, page.evaluate_script("Object.keys(window.HosAlivioFeed.PERSONA).length")
    assert_equal "ri-sparkling-2-line", page.evaluate_script("window.HosAlivioFeed.AI_ICON")

    errors = page.driver.browser.logs.get(:browser).select { |l| l.level == "SEVERE" }
                .reject { |l| l.message.include?("favicon") }
    assert_empty errors.map(&:message), "console errors on the Mission Stage"
  end

  test "a nav destination renders inside the shell and the back icon returns to the Stage" do
    sign_in_as(@admin)
    visit dashboard_path

    click_link "Patients"
    assert_current_path patients_path
    assert_selector "aside[data-sidebar-target='sidebar']", visible: true   # rail survived the trip
    assert_selector "h2", text: "Patients"                                  # banner title

    find("a[aria-label='Back to Mission Stage']").click
    assert_current_path dashboard_path
  end

  # ── phone ─────────────────────────────────────────────────────────────────

  test "on a phone the rail is hidden but the hamburger opens it" do
    sign_in_as(@admin)
    resize_to_phone
    visit patients_path

    rail = find("aside[data-tab-name='nav']", visible: :all)
    assert_not rail.visible?, "rail should start closed on a phone"

    find("button[aria-label='Open menu']").click
    assert rail.visible?, "hamburger did not open the nav drawer"

    within(rail) { click_button "Close menu" rescue find("button[aria-label='Close menu']").click }
    assert_not rail.visible?, "drawer did not close"
  end

  test "no page scrolls sideways on a phone" do
    create_user(agency: @agency, full_name: "Nina Nurse", roles: %w[rn])
    sign_in_as(@admin)
    resize_to_phone

    [ patients_path, team_members_path, branches_path, inquiries_path ].each do |path|
      visit path
      # The page body must never scroll horizontally — wide content (the team
      # table) scrolls inside its own container instead.
      overflow = page.evaluate_script(
        "document.documentElement.scrollWidth - document.documentElement.clientWidth"
      )
      assert_operator overflow, :<=, 1, "#{path} overflows horizontally by #{overflow}px at 375w"
    end
  end
end
