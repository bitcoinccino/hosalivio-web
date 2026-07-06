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

  def ask
    @query = params[:q].to_s.strip
    ActsAsTenant.with_tenant(current_user.agency) do
      command = classify(@query)
      if command
        # Fast path: a recognized oversight report, computed directly (no LLM).
        @title = Admin::Overview::COMMANDS[command]
        @items = Admin::Overview.run(command, current_user.agency)
      else
        # Anything else → HosAlivio answers in natural language, grounded in a
        # live agency snapshot. Falls back to the command nudge if there's no
        # model / no answer (e.g. no API key in CI).
        @answer = freeform_answer(@query)
      end
    end
  end

  private

  def classify(query)
    return "pending_items" if query.blank?
    COMMAND_ROUTES.each { |pattern, command| return command if pattern.match?(query) }
    nil
  end

  # A conversational, agency-grounded answer for free-form questions. Returns
  # the answer string, or nil (→ the view shows the command nudge).
  def freeform_answer(query)
    return nil if query.blank?

    system = <<~SYS.strip
      You are HosAlivio, an operations assistant for a hospice-agency manager.
      Answer the manager's question using ONLY the agency snapshot provided.
      Be warm but concise — a sentence or two, or a short list. If the snapshot
      doesn't contain the answer, say you don't have that detail and point them
      to the closest report: today's priorities, patients needing attention,
      compliance status, new referrals, or daily report. Never invent patient
      names, counts, or clinical facts. This is operational oversight only — no
      medical advice, and nothing here is written to a patient's chart.
    SYS
    user = "Agency snapshot (#{Date.current.strftime('%b %-d, %Y')}):\n\n#{agency_snapshot}\n\nManager asked: #{query}"

    HosalivioBrain.complete_text(system: system, user: user)
  end

  # Compact, labeled digest of the five oversight reports — the grounding
  # context for a free-form answer.
  def agency_snapshot
    Admin::Overview::COMMANDS.map do |cmd, title|
      items = Admin::Overview.run(cmd, current_user.agency)
      lines = items.first(8).map { |it| "- #{it.text}" }
      lines = [ "- (none)" ] if lines.empty?
      "#{title}:\n#{lines.join("\n")}"
    end.join("\n\n")
  end

  def authorize_manager!
    return if !current_user.family_access? && (current_user.role_names & DashboardsController::MANAGER_ROLES).any?
    redirect_to dashboard_path, status: :see_other, alert: "That's a manager tool."
  end
end
