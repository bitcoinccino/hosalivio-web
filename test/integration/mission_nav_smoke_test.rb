require "test_helper"

# Every destination the Mission Stage nav links to now renders inside
# layouts/mission — the nav rail plus a banner carrying a back-to-Stage icon and
# the page's title. Before, each rendered standalone: following a nav link
# dropped the rail entirely and every page hand-rolled its own back link.
class MissionNavSmokeTest < ActionDispatch::IntegrationTest
  # path => the banner title, which comes from MissionNavHelper::NAV.
  PAGES = {
    "/inquiries"    => "Referrals",
    "/admissions"   => "Admissions",
    "/patients"     => "Patients",
    "/calendar"     => "Calendar",
    "/branches"     => "Branches",
    "/team_members" => "Team"
  }.freeze

  setup do
    @agency = create_agency
    @admin  = create_user(agency: @agency, full_name: "Ada Admin", roles: %w[admin])
    sign_in @admin
  end

  test "every nav destination renders inside the Mission shell" do
    PAGES.each do |path, title|
      get path
      assert_response :success, "#{path} did not render (#{response.status})"

      assert_includes response.body, 'data-sidebar-target="sidebar"',      "#{path}: nav rail missing"
      assert_includes response.body, 'aria-label="Back to Mission Stage"', "#{path}: back icon missing"
      assert_includes response.body, title,                                "#{path}: banner title missing"
    end
  end

  test "the back icon always points at the Mission Stage" do
    PAGES.each_key do |path|
      get path
      assert_select "a[aria-label='Back to Mission Stage'][href=?]", dashboard_path, {},
                    "#{path}: back icon should link to the Stage, not history"
    end
  end

  test "the current page is the highlighted nav entry" do
    get "/patients"
    # nav_on styling marks the active entry; on /patients that must be Patients.
    assert_select "a[href=?]", patients_path do |links|
      assert links.any? { |l| l["class"].to_s.include?("bg-[#D9D5CD]") },
             "Patients should be the highlighted rail entry on /patients"
    end
  end

  test "the Mission Stage itself still renders the shared rail and keeps its live feed" do
    get dashboard_path
    assert_response :success
    assert_includes response.body, 'data-sidebar-target="sidebar"'
    assert_includes response.body, "Live activity"
    # The Stage is the hub — it has no back-to-itself icon.
    assert_not_includes response.body, 'aria-label="Back to Mission Stage"'
  end

  # ── mobile ────────────────────────────────────────────────────────────────
  # The rail is hidden below md, so without a way to open it a phone user would
  # be stranded on whatever page they landed on.

  test "every nav page can open the rail as a drawer on a phone" do
    PAGES.each_key do |path|
      get path
      # Hamburger exists, is phone-only, and targets the rail's tab.
      assert_select "button[aria-label='Open menu'][data-tab-name=?]", "nav", {},
                    "#{path}: no way to open the nav on mobile"
      assert_select "button[aria-label='Open menu']" do |els|
        assert_includes els.first["class"], "md:hidden", "#{path}: hamburger should not show on desktop"
      end
      # The rail is the tab that button activates.
      assert_select "aside[data-tab-name=?]", "nav", {}, "#{path}: rail is not the drawer target"
      # And it can be closed again.
      assert_select "button[aria-label='Close menu']", {}, "#{path}: drawer has no close"
    end
  end

  test "the Stage keeps its own census/stage/activity switcher" do
    get dashboard_path
    # The Stage's rail is the "census" tab — renaming it would break the Stage's
    # existing bottom tab bar.
    assert_select "aside[data-tab-name=?]", "census"
    assert_select "aside[data-tab-name='nav']", false, "the Stage should not use the drawer tab name"
  end

  test "nav pages render no fixed-height wrapper that would fight the shell" do
    PAGES.each_key do |path|
      get path
      # layouts/mission owns the viewport and supplies the scroll container; a
      # page-level min-h-screen inside it produces a second scrollbar.
      body = response.body[/<main.*<\/main>/m].to_s
      # Guard: an unmatched regex would make the assertion below pass vacuously.
      assert_not_empty body, "#{path}: no <main> found — this check would be meaningless"
      assert_not_includes body, "min-h-screen", "#{path}: page still forces min-h-screen inside the shell"
    end
  end

  test "the team table scrolls instead of squashing on a phone" do
    create_user(agency: @agency, full_name: "Nina Nurse", roles: %w[rn])
    get "/team_members"
    assert_select "div.overflow-x-auto table", {}, "team table must scroll inside its own container"
    # Lowest-value columns drop out below the breakpoint rather than crushing.
    assert_select "td.hidden.md\\:table-cell", {}, "caseload column should be desktop-only"
  end

  test "a clinician sees no manager-only nav entries" do
    sign_in create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    get calendar_path
    assert_response :success
    assert_select "a[href=?]", branches_path, false, "Branches is manager-only"
    assert_select "a[href=?]", team_members_path, false, "Team is manager-only"
    # Calendar carries no :manager flag — every role keeps it.
    assert_select "a[href=?]", calendar_path
  end
end
