# Last-line defense against an agent doing something its role
# explicitly forbids. The brain prompts already contain the cannot_do
# list, but LLMs drift. AgentGuard reads the action a brain proposes
# and rejects it (without raising) when it maps to a forbidden
# capability for that role.
#
# Maps each cannot_do bullet to either:
#   * an action key the AgentTriager would call (e.g. write_med_order)
#   * a substring sniff against the proposed body / params
#
# Returns AgentGuard::Result(allowed:, reason:). The caller (typically
# AgentTriager#apply) silently no-ops when allowed=false and logs the
# reason so an audit row exists.
#
# Adding a new prohibition: edit RULES below. Each rule is a tuple of
#   role, cannot_do_key, ->(decision) -> truthy when violated.
# Skipped if the agent's cannot_do list doesn't include the key.

class AgentGuard
  Result = Struct.new(:allowed, :reason, keyword_init: true)

  RULES = [
    # Pharmacy can only write deliveries linked to an active order.
    {
      role: "pharmacy",
      key:  "accept_orders_without_active_medication_order_link",
      check: ->(d) { d[:action] == "write_pharm_delivery" && d[:params].to_h["medication_order_id"].blank? }
    },

    # Pharmacy must not change doses or prescribe.
    {
      role: "pharmacy",
      key:  "change_doses_or_prescribe",
      check: ->(d) { d[:action] == "write_med_order" }
    },

    # MD must include a patient_id on every order.
    {
      role: "md",
      key:  "write_orders_without_patient_id",
      check: ->(d) { d[:action] == "write_med_order" && d[:params].to_h["patient_id"].blank? }
    },

    # Aides can never administer or document medications.
    {
      role: "aide",
      key:  "administer_medications",
      check: ->(d) { d[:action] == "write_med_order" || d[:action] == "write_pharm_delivery" }
    },

    # Insurance must not file an NOE without a certified eval.
    {
      role: "insurance",
      key:  "file_without_the_mds_signed_recert",
      check: lambda do |d|
        next false unless d[:action] == "file_noe"
        eval_id = d[:params].to_h["eval_id"]
        next false if eval_id.blank?
        rec = PreAdmitEval.find_by(id: eval_id)
        rec.nil? || !(rec.status_certified? || rec.status_noe_filed?)
      end
    },

    # Only admissions speaks family-facing prose. Other roles' prose
    # is allowed but flagged as clinician_only by AgentTriager#write_note.
    # Keeping a soft check here for the broadcast_reply action.
    {
      role: "rn",
      key:  "speak_for_md_or_sw",
      check: ->(d) { d[:action] == "broadcast_reply" }
    }
  ].freeze

  def self.validate(role, decision)
    role_s = role.to_s
    cannot = AgentRegistry.cannot_do_for(role_s)
    return Result.new(allowed: true) if cannot.empty?

    decision = (decision || {}).with_indifferent_access
    RULES.each do |rule|
      next unless rule[:role] == role_s
      next unless cannot.include?(rule[:key])
      next unless rule[:check].call(decision.symbolize_keys)
      return Result.new(allowed: false, reason: "#{role_s} cannot #{rule[:key]}")
    end
    Result.new(allowed: true)
  end

  # Bang variant for callers that prefer the throw style; logs and
  # returns the falsy Result rather than raising, so production never
  # crashes a triage chain on a guard hit.
  def self.validate!(role, decision)
    res = validate(role, decision)
    Rails.logger.warn("[AgentGuard:#{role}] blocked: #{res.reason}") unless res.allowed
    res
  end
end
