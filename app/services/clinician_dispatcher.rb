# When a clinician explicitly delegates to HosAlivio in their team
# huddle message ("@HosAlivio please send a comfort kit refill"), this
# service classifies the intent and dispatches the matching agent action.
#
# The result is the same green action banner + audit trail that family-
# triggered triage produces — so chart history reads identically whether
# Pascal asked or Carlos did.
#
# MVP uses keyword matching (no LLM call) to keep the round-trip cheap
# and predictable. Will swap in HosalivioBrain.dispatch_for_clinician
# later when the regex stops covering enough cases.
#
# Usage:
#   ClinicianDispatcher.call(note: note, requester: user)
#   # => { dispatched: true, intent: "pharmacy_refill", banner_id: <note.id> }
#   # or { dispatched: false, reason: "no_intent_matched" }

class ClinicianDispatcher
  MENTION_RE = /@hosalivio\b/i

  # Ordered keyword → intent map. First match wins. Loose matching on
  # purpose: clinicians type quickly and won't quote the menu.
  INTENT_MAP = [
    [/\b(comfort\s*kit|comfort-kit)\b/i,                       :pharmacy_comfort_kit],
    [/\b(refill|out\s*of|running\s*low|need\s*more)\b/i,       :pharmacy_refill],
    [/\b(chaplain|spiritual)\b/i,                              :chaplain_request],
    [/\b(social\s*work(er)?|psychosocial)\b/i,                 :sw_request],
    [/\b(dme|equipment|hospital\s*bed|wheelchair|walker|oxygen|commode)\b/i, :dme_order],
    [/\b(noe|notice\s*of\s*election|insurance\s*file)\b/i,     :noe_file]
  ].freeze

  # Phrases that read like a clinician update for the family member
  # (status, ETA, reassurance). Anything matching auto-promotes the
  # message visibility to family-visible. Default is team-only.
  FAMILY_UPDATE_RE = /\b(i'?m on my way|on my way|i'?ll be (there|over)|coming over|arriving|just left|stopping by|see you in|ETA \d|she'?s resting|he'?s resting|comfortable now|sleeping peacefully|all calm|everything is calm|doing okay now|call me if|reach out if|let me know if anything changes)\b/i

  # Returns :family or :team. Default :team — most clinician chatter
  # is coordination. Auto-promotes to :family on phrasing patterns
  # that read like an update FOR the family member.
  def self.classify_audience(body)
    return :family if body.to_s.match?(FAMILY_UPDATE_RE)
    :team
  end

  # Should this clinician message wake an agent? Either an explicit
  # @HosAlivio mention OR an action verb (refill, dispatch, equipment,
  # NOE) shows up in the body.
  def self.should_dispatch?(body)
    return true if body.to_s.match?(MENTION_RE)
    INTENT_MAP.any? { |pattern, _| body.to_s.match?(pattern) }
  end

  Result = Struct.new(:dispatched, :intent, :reason, :note_id, keyword_init: true)

  # Brain-driven entry point. Takes a HosalivioBrain.classify_clinician_message
  # result and dispatches the matching agent action.
  def self.execute(note:, requester:, action:, ack: nil)
    return Result.new(dispatched: false, reason: "no_action") if action.blank? || action == "no_action"
    d = new(note, requester)
    intent = action.to_sym
    case intent
    when :pharmacy_comfort_kit, :pharmacy_refill
      d.send(:dispatch_pharmacy, intent, ack: ack)
    when :dme_order
      d.send(:dispatch_dme, ack: ack)
    when :chaplain_request
      d.send(:dispatch_role_handoff, "chaplain", "chaplain_request", ack: ack)
    when :sw_request
      d.send(:dispatch_role_handoff, "social_worker", "sw_request", ack: ack)
    when :noe_file
      d.send(:dispatch_role_handoff, "insurance", "noe_file", ack: ack)
    else
      return Result.new(dispatched: false, reason: "unknown_action:#{action}")
    end
    Result.new(dispatched: true, intent: action.to_s)
  end

  def self.call(note:, requester:)
    new(note, requester).call
  end

  def self.mentions_hosalivio?(body)
    body.to_s.match?(MENTION_RE)
  end

  def initialize(note, requester)
    @note      = note
    @requester = requester
    @patient   = note.patient
    @agency    = note.agency
  end

  def call
    intent = classify(@note.body)
    return Result.new(dispatched: false, reason: "no_intent_matched") unless intent

    Current.agency           = @agency
    Current.agent_id         = "admissions"
    Current.agent_session_id = "hosalivio-dispatch-#{SecureRandom.hex(4)}"

    case intent
    when :pharmacy_comfort_kit, :pharmacy_refill then dispatch_pharmacy(intent)
    when :chaplain_request                       then dispatch_role_handoff("chaplain", "chaplain_request")
    when :sw_request                             then dispatch_role_handoff("social_worker", "sw_request")
    when :dme_order                              then dispatch_dme
    when :noe_file                               then dispatch_role_handoff("insurance", "noe_file")
    else
      Result.new(dispatched: false, reason: "unhandled_intent:#{intent}")
    end
  ensure
    Current.reset
  end

  private

  def classify(body)
    INTENT_MAP.each do |pattern, intent|
      return intent if body.to_s.match?(pattern)
    end
    nil
  end

  # Pharmacy intents materialize the actual PharmacyDelivery record so
  # the green 'Pharmacy Dispatched' banner shows up in the audit trail.
  def dispatch_pharmacy(intent, ack: nil)
    kind = intent == :pharmacy_comfort_kit ? "comfort_kit" : "refill"
    AgentTriager.new(role: "pharmacy", agency: @agency, depth: 1).apply({
      action:    "write_pharm_delivery",
      params:    { patient_id: @patient.id, kind: kind, urgency: "urgent" },
      reasoning: "Dispatched by #{@requester.full_name} via team chat",
      source:    "dispatch:clinician"
    })
    post_ack(ack || "Pharmacy notified, #{kind.tr('_', ' ')} on the way.")
    Result.new(dispatched: true, intent: intent.to_s)
  end

  def dispatch_dme(ack: nil)
    AgentTriager.new(role: "dme", agency: @agency, depth: 1).apply({
      action:    "write_dme_order",
      params:    { patient_id: @patient.id, equipment_type: "other", quantity: 1, urgency: "urgent" },
      reasoning: "Dispatched by #{@requester.full_name} via team chat",
      source:    "dispatch:clinician"
    })
    post_ack(ack || "DME notified, equipment request on the way.")
    Result.new(dispatched: true, intent: :dme_order.to_s)
  end

  # Role handoffs that don't have a one-line action yet (chaplain visits,
  # SW meetings, NOE filings) just emit the handoff event + an ack note
  # so the right human role sees it on the Mission Stage queue.
  def dispatch_role_handoff(role, intent_label, ack: nil)
    Current.agency           ||= @agency
    Current.agent_id         ||= "admissions"
    Current.agent_session_id ||= "hosalivio-dispatch-#{SecureRandom.hex(4)}"
    AgentEvent.create!(
      agency:           @agency,
      agent_id:         "admissions",
      agent_session_id: Current.agent_session_id,
      action:           "handoff",
      subject:          @patient,
      change_set:       { target_role: role, intent: intent_label, urgency: "normal",
                          requested_by: @requester.full_name },
      happened_at:      Time.current
    )
    label_map = { "chaplain" => "Chaplain visit requested.",
                  "social_worker" => "Social work request sent.",
                  "insurance" => "NOE filing queued." }
    post_ack(ack || label_map[role] || "Routed to #{role}.")
    Result.new(dispatched: true, intent: intent_label)
  end

  # Posts a short HosAlivio reply into the team-only audit trail so
  # the requester sees the dispatch confirmed inline.
  def post_ack(text)
    Note.create!(
      agency:         @agency,
      patient:        @patient,
      author_role:    "admissions",
      body:           "HosAlivio: #{text}",
      urgency:        "normal",
      source:         "system",
      clinician_only: true
    )
  rescue ActiveRecord::RecordInvalid
    nil
  end
end
