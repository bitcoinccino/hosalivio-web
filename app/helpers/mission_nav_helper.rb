# The Mission Stage nav, defined once. Both the sidebar rail and the banner on
# each nav page read from here — the banner's title and icon ARE the nav entry's
# label and icon, so a page can't drift from the link that reaches it.
#
# :manager  — only shown to admin/admissions (mirrors the old is_mgr_nav check)
# :soon     — rendered greyed out, no link
module MissionNavHelper
  NAV = [
    { key: :stage,      label: "Mission Stage",  icon: "ri-radar-line",          path: :dashboard_path,             group: nil },
    { key: :referrals,  label: "Referrals",      icon: "ri-inbox-line",          path: :inquiries_path,             group: "Admissions",   manager: true },
    { key: :admissions, label: "Admissions",     icon: "ri-folder-history-line", path: :admissions_queue_path,      group: "Admissions",   manager: true },
    { key: :patients,   label: "Patients",       icon: "ri-team-line",           path: :patients_path,              group: "Admissions",   manager: true },
    { key: :calendar,   label: "Calendar",       icon: "ri-calendar-line",       path: :calendar_path,              group: "Schedule" },
    { key: :branches,   label: "Branches",       icon: "ri-map-pin-line",        path: :branches_path,              group: "Organization", manager: true },
    { key: :team,       label: "Team",           icon: "ri-team-line",           path: :team_members_path,          group: "Organization", manager: true },
    { key: :features,   label: "Features",       icon: "ri-toggle-line",         path: :edit_agency_features_path,  group: "Settings",     manager: true },
    { key: :idg,        label: "IDG Review",     icon: "ri-group-line",          group: "Reports", soon: true },
    { key: :census,     label: "Census Report",  icon: "ri-file-list-3-line",    group: "Reports", soon: true }
  ].freeze

  BY_KEY = NAV.index_by { |i| i[:key] }.freeze

  def mission_nav_item(key)
    BY_KEY[key&.to_sym]
  end

  # Manager-only entries drop out for clinicians, matching the previous
  # is_mgr_nav gate on the Admissions/Organization/Settings groups.
  def mission_nav_visible
    manager = (current_user.role_names & %w[admin admissions]).any?
    NAV.reject { |i| i[:manager] && !manager }
  end

  # Count for the Referrals badge. Only the dashboard used to set
  # @pending_inquiries; the sidebar now renders on six more pages, so it falls
  # back to querying rather than silently showing no badge.
  def mission_nav_pending_inquiries
    @pending_inquiries ||= Inquiry.status_new_lead.count
  end
end
