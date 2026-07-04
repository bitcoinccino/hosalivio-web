module MissionStageHelper
  # Buckets an agent event into one of four activity lanes for the Mission
  # Stage feed. Mirrored client-side by `categorize(p)` in the dashboards
  # show view's live-feed script — keep the two in sync.
  #
  #   admissions → intake funnel (referrals, inquiries, handoffs from HosAlivio)
  #   clinical   → bedside care (RN/MD/aide/SW/chaplain, meds, visits, evals)
  #   family     → family-facing chat + concerns
  #   ops        → pharmacy / DME / insurance / billing / DON / system
  def activity_category(event)
    role    = event.agent_id.to_s
    subject = event.subject_type.to_s
    action  = event.action.to_s

    return "admissions" if role == "admissions"
    return "admissions" if subject == "Inquiry" || (subject == "Patient" && action == "create")
    return "family"     if %w[family front_door_inbound].include?(role)
    return "ops"        if %w[pharmacy dme insurance billing don system].include?(role)
    return "clinical"   if %w[rn md aide social_worker chaplain].include?(role)

    "ops"
  end

  # Ordered lane definitions: [key, label, color]. Drives the filter chips
  # and the per-bubble category tag.
  ACTIVITY_LANES = [
    [ "admissions", "Admissions", "#2B4A7A" ],
    [ "clinical",   "Clinical",   "#2F6F4E" ],
    [ "family",     "Family",     "#D97757" ],
    [ "ops",        "Ops",        "#6B665F" ]
  ].freeze

  def activity_lane_meta(category)
    ACTIVITY_LANES.find { |key, _l, _c| key == category } || [ "ops", "Ops", "#6B665F" ]
  end
end
