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
        @title = Admin::Overview::COMMANDS[command]
        @items = Admin::Overview.run(command, current_user.agency)
        @known = true
      else
        @known = false
      end
    end
  end

  private

  def classify(query)
    return "pending_items" if query.blank?
    COMMAND_ROUTES.each { |pattern, command| return command if pattern.match?(query) }
    nil
  end

  def authorize_manager!
    return if !current_user.family_access? && (current_user.role_names & DashboardsController::MANAGER_ROLES).any?
    redirect_to dashboard_path, status: :see_other, alert: "That's a manager tool."
  end
end
