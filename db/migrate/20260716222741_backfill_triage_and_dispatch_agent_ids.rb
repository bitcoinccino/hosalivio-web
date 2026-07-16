# "admissions" had become the catch-all agent identity: family-chat triage
# (HosalivioTriager) and clinician @-mention routing (ClinicianDispatcher) both
# stamped it, so the Mission Stage narrated both as "HosAlivio (Admissions)" and
# filed them under the Admissions lane. HosAlivio does no admissions work beyond
# the Admission RN flow, so those rows were simply mislabeled.
#
# Both services now stamp their own identity ("triage" / "dispatch"). This moves
# the history to match. agent_session_id is the discriminator — it was always
# distinct per service, even while agent_id wasn't:
#
#   hosalivio-claude-*  / hosalivio-openrouter-*  triage!               -> triage
#   hosalivio-fallback-*                          triage! (regex path)  -> triage
#   hosalivio-family-qa-*                         answer_family!        -> triage
#   hosalivio-dispatch-*                          ClinicianDispatcher   -> dispatch
#   hosalivio-inquiry-*                           genuine admissions    -> untouched
#
# Scoped by agent_id so re-running is a no-op, and reversible because the session
# prefixes still identify each set afterwards.
class BackfillTriageAndDispatchAgentIds < ActiveRecord::Migration[8.1]
  TRIAGE_PREFIXES   = %w[hosalivio-claude- hosalivio-openrouter- hosalivio-fallback- hosalivio-family-qa-].freeze
  DISPATCH_PREFIXES = %w[hosalivio-dispatch-].freeze

  def up
    say_with_time("admissions -> triage")   { relabel(from: "admissions", to: "triage",   prefixes: TRIAGE_PREFIXES) }
    say_with_time("admissions -> dispatch") { relabel(from: "admissions", to: "dispatch", prefixes: DISPATCH_PREFIXES) }
  end

  def down
    say_with_time("triage -> admissions")   { relabel(from: "triage",   to: "admissions", prefixes: TRIAGE_PREFIXES) }
    say_with_time("dispatch -> admissions") { relabel(from: "dispatch", to: "admissions", prefixes: DISPATCH_PREFIXES) }
  end

  private

  # Returns the affected row count, which say_with_time prints.
  def relabel(from:, to:, prefixes:)
    matcher = prefixes.map { "agent_session_id LIKE ?" }.join(" OR ")
    AgentEvent.where(agent_id: from)
              .where(matcher, *prefixes.map { |p| "#{p}%" })
              .update_all(agent_id: to)
  end
end
