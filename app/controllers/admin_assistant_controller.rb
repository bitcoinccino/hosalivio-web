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
