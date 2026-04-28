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
  # Persona helpers — pull names from AgentRegistry, role labels from
  # the existing HosalivioTriager constant so we read 'Simone (Pharmacy)'
  # / 'Marcus (DME)' / 'Geoginio (Chaplain)' / 'Nickla (Social Worker)'
  # consistently across the chat audit trail.
  def persona(role)
    name  = AgentRegistry.persona_for(role)
    label = HosalivioTriager::ROLE_LABELS[role.to_s] || role.to_s.titleize
    name ? "#{name} (#{label})" : label
  end

  def dispatch_pharmacy(intent, ack: nil)
    kind = intent == :pharmacy_comfort_kit ? "comfort_kit" : "refill"
    # Refills must link to an active medication_order so the AgentGuard
    # rule passes and Simone has a real row to refill against. Pick the
    # patient's most recent active order; nil here would (correctly)
    # trigger the guard block.
    medication_order_id =
      if kind == "refill"
        @patient.medication_orders.where(status: :active).order(created_at: :desc).first&.id
      end

    delivery = AgentTriager.new(role: "pharmacy", agency: @agency, depth: 1).apply({
      action:    "write_pharm_delivery",
      params:    { patient_id: @patient.id, kind: kind, urgency: "urgent",
                   medication_order_id: medication_order_id }.compact,
      reasoning: "Dispatched by #{@requester.full_name} via team chat",
      source:    "dispatch:clinician"
    })

    unless delivery
      reason = kind == "refill" && medication_order_id.nil? ?
        "no active medication order to refill" :
        "pharmacy guardrail blocked the delivery"
      post_guardrail_block(reason)
      return Result.new(dispatched: false, reason: reason, intent: intent.to_s)
    end

    post_ack(ack || "#{persona('pharmacy')} notified, #{kind.tr('_', ' ')} on the way.")
    Result.new(dispatched: true, intent: intent.to_s)
  end

  def dispatch_dme(ack: nil)
    dme = AgentTriager.new(role: "dme", agency: @agency, depth: 1).apply({
      action:    "write_dme_order",
      params:    { patient_id: @patient.id, equipment_type: "other", quantity: 1, urgency: "urgent" },
      reasoning: "Dispatched by #{@requester.full_name} via team chat",
      source:    "dispatch:clinician"
    })
    unless dme
      post_guardrail_block("DME guardrail blocked the order")
      return Result.new(dispatched: false, reason: "guard_blocked", intent: :dme_order.to_s)
    end
    post_ack(ack || "#{persona('dme')} notified, equipment request on the way.")
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
    label_map = { "chaplain" => "visit requested.",
                  "social_worker" => "request sent.",
                  "insurance" => "NOE filing queued." }
    default = "#{persona(role)} #{label_map[role] || 'routed.'}"
    post_ack(ack || default)
    Result.new(dispatched: true, intent: intent_label)
  end

  # Posts a short HosAlivio reply into the team-only audit trail so
  # the requester sees the dispatch confirmed inline.
  def post_ack(text)
    Note.create!(
      agency:         @agency,
      patient:        @patient,
      author_role:    "admissions",
      # [HOSALIVIO_ACK] prefix triggers the bot-avatar pill renderer
      # in the chat partial + Cable JS. Strip the prefix when displayed.
      body:           "[HOSALIVIO_ACK] #{text}",
      urgency:        "normal",
      source:         "system",
      clinician_only: true
    )
  rescue ActiveRecord::RecordInvalid
    nil
  end

  # Visible "the system stopped this from happening" note. Body is
  # prefixed with [GUARDRAIL_BLOCKED] so the chat partial + JS renderer
  # can paint the row in a distinct red pill instead of letting it
  # blend in with the regular audit log.
  def post_guardrail_block(reason)
    Note.create!(
      agency:         @agency,
      patient:        @patient,
      author_role:    "admissions",
      body:           "[GUARDRAIL_BLOCKED] #{reason}",
      urgency:        "urgent",
      source:         "system",
      clinician_only: true
    )
  rescue ActiveRecord::RecordInvalid
    nil
  end
end
