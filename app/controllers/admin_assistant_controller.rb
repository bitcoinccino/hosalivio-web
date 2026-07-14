# Agency-level "Ask HosAlivio" — oversight questions a manager types on the
# Mission Stage dashboard. Answers are agency-scoped and ephemeral (rendered into
# a turbo-frame), never persisted to a patient's chart — that's the whole point
# of a separate surface from the patient chat.
#
# First slice: "today's pending items". More commands (compliance status, missing
# documents, daily report) plug into the classifier below.
class AdminAssistantController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_manager!

  # Forgiving keyword routing → an Admin::Overview command. Ordered: more specific
  # patterns first (e.g. "patients needing attention" before the generic
  # priorities catch-all). Blank input defaults to today's priorities.
  COMMAND_ROUTES = [
    [ /\b(?:patients?\s+(?:needing|that\s+need)\s+attention|needs?\s+attention|who\s+needs|at[-\s]?risk)\b/i, "patients_needing_attention" ],
    [ /\bcompliance\b/i,                                                                                     "compliance_status" ],
    [ /\b(?:new\s+)?referrals?\b|\bintake\s+(?:queue|status)\b/i,                                            "new_referrals" ],
    [ /\b(?:daily\s+report|end[-\s]?of[-\s]?day|morning\s+huddle|generate\s+(?:a\s+)?report)\b/i,            "daily_report" ],
    [ /\b(?:priorit|pending|today|attention|overview|blocker|noe|due|summary|standup)\b/i,                  "pending_items" ]
  ].freeze

  # Tappable follow-up prompts rendered beneath each answer, so a manager can
  # keep the conversation going with one tap (like the public chat's chips).
  # Keyed by the report just shown; freeform / unmatched answers get the
  # DEFAULT set. Each entry is a `q` that re-enters #ask on click.
  FOLLOWUP_SUGGESTIONS = {
    "pending_items"              => [ "patients needing attention", "new referrals", "daily report" ],
    "patients_needing_attention" => [ "compliance status", "overdue visits", "today's priorities" ],
    "compliance_status"          => [ "expiring licenses", "recertifications this week", "patients needing attention" ],
    "new_referrals"              => [ "unassigned patients", "today's priorities", "daily report" ],
    "daily_report"               => [ "patients needing attention", "new referrals", "who's on call" ]
  }.freeze
  DEFAULT_FOLLOWUPS = [ "today's priorities", "patients needing attention", "compliance status", "daily report" ].freeze

  def ask
    @query = params[:q].to_s.strip
    ActsAsTenant.with_tenant(current_user.agency) do
      command = classify(@query)
      if command
        # Fast path: a recognized oversight report, computed directly (no LLM
        # — the numbers stay exact). HosAlivio still delivers it, in her voice.
        @title = Admin::Overview::COMMANDS[command]
        @items = Admin::Overview.run(command, current_user.agency)
        @lead  = report_lead(command, @title, @items)
      else
        # Anything else → HosAlivio answers in natural language, grounded in a
        # live agency snapshot. If there's no model (e.g. no API key), a warm
        # canned reply still handles greetings/help; otherwise the nudge.
        @answer = freeform_answer(@query) || canned_reply(@query)
      end
      # Always offer a couple of tappable next steps so no answer dead-ends.
      @followups = followups_for(command)
    end

    respond_to do |format|
      format.turbo_stream                              # appends bubbles to the thread
      format.html { redirect_to dashboard_path }       # JS-off fallback
    end
  end

  private

  def classify(query)
    return "pending_items" if query.blank?
    COMMAND_ROUTES.each { |pattern, command| return command if pattern.match?(query) }
    nil
  end

  # Two-to-three follow-up prompts to render as chips, minus whatever the
  # manager just asked (so we don't suggest the current view back to them).
  def followups_for(command)
    (FOLLOWUP_SUGGESTIONS[command] || DEFAULT_FOLLOWUPS)
      .reject { |q| q.casecmp?(@query) }
      .first(3)
  end

  # Reports that always emit a fixed set of metric lines (even all-zero) — a
  # status snapshot, not a list of findings.
  STATUS_COMMANDS = %w[compliance_status daily_report].freeze

  # HosAlivio's single-sentence framing over a deterministic report — the topic
  # is folded in, so the answer needs no separate title label.
  def report_lead(command, title, items)
    topic = title.to_s.downcase

    return "You're all caught up on #{topic} — nothing needs attention right now." if items.empty?

    urgent = items.count(&:urgent)

    if STATUS_COMMANDS.include?(command)
      # Metric snapshot: don't call the count "items found".
      return "#{title} — all clear right now." if urgent.zero?

      "#{title} — #{urgent} need#{'s' if urgent == 1} attention:"
    else
      summary = "#{items.size} #{'item'.pluralize(items.size)}"
      summary += ", #{urgent} urgent" if urgent.positive?
      "#{title} — #{summary}:"
    end
  end

  # A conversational, agency-grounded answer for free-form questions. Returns
  # the answer string, or nil (→ the view shows the command nudge).
  def freeform_answer(query)
    return nil if query.blank?

    system = <<~SYS.strip
      You are HosAlivio, a warm and efficient operations assistant for hospice agency managers.

      Answer the manager's question using ONLY the agency snapshot provided. The snapshot includes:
      - Current census and active patients
      - Staff and branch information
      - Today's oversight reports (priorities, patients needing attention, compliance status, new referrals, daily report)

      Guidelines:
      - Be warm but concise — use 1-2 sentences or a short bullet list.
      - If the snapshot doesn't have the answer, say "I don't have that detail right now" and suggest the closest relevant report.
      - Never invent patient names, numbers, or clinical facts.
      - This is operational oversight only. Do not give medical advice or write anything to a patient's chart.

      Always end with a helpful offer if appropriate (e.g., "Let me know if you'd like details on anything specific.").
    SYS
    user = "Agency snapshot as of #{Time.current.strftime('%b %-d, %Y at %-l:%M %p %Z')}:\n\n#{agency_snapshot}\n\nManager asked: #{query}"

    HosalivioBrain.complete_text(system: system, user: user)
  end

  # A warm, LLM-free reply for greetings / thanks / "what can you do?", so
  # HosAlivio still responds when the model is dormant. nil → the command nudge.
  def canned_reply(query)
    case query.downcase
    when /\A\s*(hi|hello|hey|yo|hiya|howdy|good\s+(?:morning|afternoon|evening))\b/, /\bhow are you\b|what'?s up\b/
      "Hi! I'm HosAlivio. Ask me for today's priorities, patients needing attention, compliance status, new referrals, or the daily report — or anything about your agency."
    when /\b(thanks|thank you|thx|appreciate)\b/
      "Anytime! Want today's priorities or a quick compliance check?"
    when /\b(help|what can you (?:do|help)|what do you do|commands|options)\b/
      "I can pull today's priorities, patients needing attention, compliance status, new referrals, or a daily report — and answer questions about your agency's current state."
    end
  end

  # Compact, labeled digest of agency state — the grounding context for a
  # free-form answer. Aggregates (not raw rows) across the admin-relevant
  # models: census, staff, branches, and the five oversight reports.
  def agency_snapshot
    [ "Agency: #{current_user.agency.name}",
      census_summary,
      staff_summary,
      branches_summary,
      reports_summary ].compact.join("\n\n")
  end

  def reports_summary
    Admin::Overview::COMMANDS.map do |cmd, title|
      items = Admin::Overview.run(cmd, current_user.agency)
      lines = items.first(8).map { |it| "- #{it.text}" }
      lines = [ "- (none)" ] if lines.empty?
      "#{title}:\n#{lines.join("\n")}"
    end.join("\n\n")
  end

  # Active, non-family staff: headcount, role mix, and license risk.
  def staff_summary
    staff = User.where(agency: current_user.agency, active: true, family_access: [ false, nil ]).includes(:roles)
    by_role = Hash.new(0)
    staff.each { |u| u.role_names.each { |r| by_role[r] += 1 } }
    role_mix = by_role.sort_by { |_, n| -n }.map { |r, n| "#{n} #{r.tr('_', ' ')}" }.join(", ")

    scope    = User.where(agency: current_user.agency, active: true)
    expired  = scope.where(license_expires_on: ...Date.current).count
    expiring = scope.where(license_expires_on: Date.current..(Date.current + 60.days)).count

    lines = [ "- #{staff.size} active staff#{" (#{role_mix})" if role_mix.present?}" ]
    lines << "- #{expired} with expired licenses"                if expired.positive?
    lines << "- #{expiring} with licenses expiring within 60 days" if expiring.positive?
    "Staff:\n#{lines.join("\n")}"
  end

  # Branch roster with a rollup header, then per-branch location, staff and
  # patient counts, and service area.
  def branches_summary
    branches = Branch.where(agency: current_user.agency).order(:name).to_a
    return nil if branches.empty?

    active_count   = branches.count(&:active)
    total_patients = branches.sum(&:patient_count)
    shown          = branches.first(12)

    lines = shown.map do |b|
      loc = b.location_label.presence
      "- #{b.name}#{" (#{loc})" if loc}: #{b.staff_count} staff, #{b.patient_count} patients" \
        "#{", #{b.service_area_summary}" if b.service_area_zips.any? || b.service_area_counties.any?}" \
        "#{' [inactive]' unless b.active}"
    end

    header = "Branches — #{active_count} active, #{total_patients} patients total"
    header += " (showing #{shown.size} of #{branches.size})" if branches.size > shown.size
    "#{header}:\n#{lines.join("\n")}"
  end

  # Headcount by status, so questions like "how many active patients?" can be
  # answered from the snapshot.
  def census_summary
    scope  = Patient.where(agency: current_user.agency)
    active = scope.where(status: :active).count
    total  = scope.count
    lines  = [ "- #{active} active patients", "- #{total} patients on record" ]
    Patient.statuses.keys.reject { |s| s == "active" }.each do |status|
      n = scope.where(status: status).count
      lines << "- #{n} #{status.tr('_', ' ')}" if n.positive?
    end
    "Census:\n#{lines.join("\n")}"
  end

  def authorize_manager!
    return if !current_user.family_access? && (current_user.role_names & DashboardsController::MANAGER_ROLES).any?
    redirect_to dashboard_path, status: :see_other, alert: "That's a manager tool."
  end
end
