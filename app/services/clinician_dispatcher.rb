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
    [/\b(social\s*work(er)?|sw\b|psychosocial)\b/i,            :sw_request],
    [/\b(dme|equipment|hospital\s*bed|wheelchair|walker|oxygen|commode)\b/i, :dme_order],
    [/\b(noe|notice\s*of\s*election|insurance\s*file)\b/i,     :noe_file]
  ].freeze

  Result = Struct.new(:dispatched, :intent, :reason, :note_id, keyword_init: true)

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
  def dispatch_pharmacy(intent)
    kind = intent == :pharmacy_comfort_kit ? "comfort_kit" : "refill"
    AgentTriager.new(role: "pharmacy", agency: @agency, depth: 1).apply({
      action:    "write_pharm_delivery",
      params:    { patient_id: @patient.id, kind: kind, urgency: "urgent" },
      reasoning: "Dispatched by #{@requester.full_name} via team chat",
      source:    "dispatch:clinician"
    })
    post_ack("Pharmacy notified, #{kind.tr('_', ' ')} on the way.")
    Result.new(dispatched: true, intent: intent.to_s)
  end

  def dispatch_dme
    AgentTriager.new(role: "dme", agency: @agency, depth: 1).apply({
      action:    "write_dme_order",
      params:    { patient_id: @patient.id, equipment_type: "other", quantity: 1, urgency: "urgent" },
      reasoning: "Dispatched by #{@requester.full_name} via team chat",
      source:    "dispatch:clinician"
    })
    post_ack("DME notified, equipment request on the way.")
    Result.new(dispatched: true, intent: :dme_order.to_s)
  end

  # Role handoffs that don't have a one-line action yet (chaplain visits,
  # SW meetings, NOE filings) just emit the handoff event + an ack note
  # so the right human role sees it on the Mission Stage queue.
  def dispatch_role_handoff(role, intent_label)
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
    label_map = { "chaplain" => "Chaplain visit requested",
                  "social_worker" => "Social work request sent",
                  "insurance" => "NOE filing queued" }
    post_ack(label_map[role] || "Routed to #{role}.")
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
