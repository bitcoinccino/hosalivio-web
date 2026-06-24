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
    [/\b(verify|check|confirm|review)\b.{0,40}\b(insurance|coverage|benefits?|medicare|medicaid|eligibility)\b/i, :verify_insurance],
    [/\b(insurance|coverage|benefits?|medicare|medicaid|eligibility)\b.{0,40}\b(verify|check|confirm|review)\b/i, :verify_insurance],
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

  def self.intent_for(body)
    INTENT_MAP.each do |pattern, intent|
      return intent.to_s if body.to_s.match?(pattern)
    end
    nil
  end

  Result = Struct.new(:dispatched, :intent, :reason, :note_id, keyword_init: true)

  # Dispatches a locally classified action. Slow answer generation happens
  # inside the job, after the clinician's own note has already posted.
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
    when :verify_insurance
      d.send(:dispatch_role_handoff, "insurance", "verify_insurance", ack: ack)
    when :billing_question
      d.send(:dispatch_role_handoff, "billing", "billing_question", ack: ack)
    when :admissions_handoff
      d.send(:dispatch_role_handoff, "admissions", "admissions_handoff", ack: ack)
    when :answer_question
      d.send(:answer_question)
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
  # Resolve a role to the human label Pascal should see in the ack.
  #
  # Priority:
  #   1. Real human at the patient's branch with this role
  #      ('Mark Chen (Pharmacy) notified...')
  #   2. Real human at the agency with this role (any branch)
  #   3. Agent persona from config/agents.yml as the fallback
  #      ('Simone (Pharmacy) notified...') — used when the agency
  #      hasn't onboarded a real human for this role yet
  #
  # Internally / in audit traces (AgentEvent change_set, log lines) we
  # keep the agent persona; this helper is just for clinician-facing
  # acks. So the under-the-hood Simone is still Simone, but Pascal
  # reads the real pharmacist's name.
  def persona(role)
    label = HosalivioTriager::ROLE_LABELS[role.to_s] || role.to_s.titleize
    user  = human_user_for_role(role)
    return "#{first_name_without_honorific(user)} (#{label})" if user
    name = AgentRegistry.persona_for(role)
    name ? "#{name} (#{label})" : label
  end

  HONORIFICS = %w[dr. mr. mrs. ms. mx. rev. fr. sr.].freeze

  def first_name_without_honorific(user)
    tokens = user.full_name.to_s.split.reject { |t| HONORIFICS.include?(t.downcase) }
    tokens.first.presence || user.full_name.to_s.split.first
  end

  def human_user_for_role(role)
    base = User.joins(user_roles: :role)
               .where(agency: @agency, active: true)
               .where(roles: { name: role.to_s })
    in_branch = @patient.branch_id.present? ? base.where(branch_id: @patient.branch_id) : base.none
    in_branch.first || base.first
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
    # Persistent notification so the targeted role's bell-icon actually
    # pings, not just the agent-event audit log. Looks up active users
    # with the given role at the patient's branch (or agency-wide if
    # no branch is set), and creates one Notification each.
    notify_role_users(role, intent_label)

    label_map = { "chaplain"      => "visit requested.",
                  "social_worker" => "request sent.",
                  "insurance"     => intent_label == "verify_insurance" ? "asked to verify insurance." : "NOE filing queued.",
                  "billing"       => "billing question routed.",
                  "admissions"    => "looped in." }
    default = "#{persona(role)} #{label_map[role] || 'routed.'}"
    post_ack(ack || default)
    Result.new(dispatched: true, intent: intent_label)
  end

  def notify_role_users(role, intent_label)
    base = User.unscoped
                 .joins(user_roles: :role)
                 .where(agency_id: @agency.id, active: true, family_access: false)
                 .where(roles: { name: role })
    base = base.where(branch_id: @patient.branch_id) if @patient.branch_id
    base.find_each do |target|
      next if Notification.exists?(user: target, kind: "role_handoff", linked: @patient, title: intent_title(intent_label))
      Notification.create!(
        agency: @agency,
        user:   target,
        kind:   "role_handoff",
        title:  "#{intent_title(intent_label)}: #{@patient.full_name}",
        linked: @patient
      )
    end
  end

  def intent_title(intent_label)
    {
      "verify_insurance"     => "Verify insurance",
      "billing_question"     => "Billing question",
      "admissions_handoff"   => "Admissions follow-up",
      "noe_file"             => "NOE filing",
      "chaplain_request"     => "Chaplain visit",
      "sw_request"           => "Social work follow-up"
    }.fetch(intent_label, intent_label.to_s.tr("_", " ").titleize)
  end

  # Q&A path: clinician asked HosAlivio a factual question about the
  # patient. Build a role-scoped context, call Claude, post the answer
  # back as a HosAlivio bot bubble. Audit-logged via AgentEvent so we
  # know what was asked, what was answered, and which role asked it.
  def answer_question
    role = (@requester.role_names & %w[rn md don admissions admin ceo aide sw social_worker chaplain]).first || "rn"
    result = HosalivioBrain.answer_clinician_question(
      question:       @note.body.to_s,
      patient:        @patient,
      role:           role,
      thread_context: recent_clinician_thread_context
    )

    if result
      post_ack(result["answer"])
      # Same notify-on-acceptance path as the family side: when the
      # clinician confirms an offer ("yes, ping admissions") the
      # brain returns a notify directive, which we execute as a
      # clinician_only urgent note that @-mentions the right human.
      if (notify = result["notify"])
        execute_notify_directive(notify)
      end
      AgentEvent.create!(
        agency:      @agency,
        agent_id:    "hosalivio_brain",
        action:      "answer_clinician_question",
        subject:     @patient,
        happened_at: Time.current,
        change_set:  {
          requester_id:   @requester.id,
          requester_role: role,
          source:         result["source"],
          chars_in:       @note.body.to_s.length,
          chars_out:      result["answer"].length,
          notified_role:  notify&.dig("role")
        }
      )
    else
      post_ack(fallback_answer_for(role))
    end
    Result.new(dispatched: true, intent: "answer_question")
  end

  def fallback_answer_for(role)
    if role.to_s == "rn"
      "I couldn't read the chart context cleanly just now. Review the patient status panel, complete any open documentation blockers, assess current symptoms, and escalate to the MD or DON if comfort or eligibility questions need review."
    else
      "I couldn't read the chart context cleanly just now. Want me to flag this to the assigned RN?"
    end
  end

  # Last 8 clinician-visible messages from this patient's thread,
  # oldest first, with bodies truncated. Includes both clinician chat
  # and HosAlivio replies/acks so the brain can interpret a "yes" in
  # the context of HosAlivio's prior offer.
  def recent_clinician_thread_context
    notes = @patient.notes
                    .where.not(id: @note.id)
                    .order(created_at: :desc).limit(8)
                    .reverse
    notes.map do |n|
      role = if n.ai_authored?
        "hosalivio"
      elsif n.author_role == "family"
        "family"
      else
        n.author_role.to_s
      end
      { role: role, body: n.body.to_s[0, 600], sent_at: n.created_at.iso8601 }
    end
  end

  # Mirrors HosalivioTriager#execute_notify but for the clinician
  # side: when an RN/MD/etc says "yes ping admissions", the brain
  # emits notify={role:..., reason:...}. We post an internal chart note
  # and create a Notification so the target sees it in-app and through
  # their configured outbound channels.
  def execute_notify_directive(notify)
    role   = notify["role"].to_s
    reason = notify["reason"].to_s.strip
    return if role.empty?
    target = resolve_clinician_for_role(role)
    return if target.nil?

    first  = target.full_name.to_s.split(/\s+/, 2).first || "team"
    reason = scrub_clinician_name_from_reason(reason, target)
    body   = "@#{first} #{reason.presence || "follow-up requested"}"
    note = Note.create!(
      agency:         @agency,
      patient:        @patient,
      author_role:    "admissions",
      body:           body,
      urgency:        "normal",
      source:         "system",
      clinician_only: true
    )
    Notification.create!(
      agency: @agency,
      user:   target,
      kind:   "mentioned",
      title:  "HosAlivio flagged a patient for your review",
      body:   "#{@patient.full_name}: #{reason.presence || "Follow-up requested."}",
      linked: note
    )
  rescue => e
    Rails.logger.warn("[ClinicianDispatcher#execute_notify_directive] #{e.class}: #{e.message}")
  end

  # Mirror of HosalivioTriager#scrub_clinician_name. Strips the
  # target clinician's own name (full / first / last) from the
  # reason text so the rendered @-mention doesn't read with the
  # name twice ("@Pascal contact Pascal Benoit").
  CONNECTOR_RE = /\b(?:with|to|by|from|for|contact|reach|reach\s+out\s+to|in|of|notify|page|page\s+in|loop\s+in|alert)\b/i.freeze

  def scrub_clinician_name_from_reason(reason, target)
    return reason if reason.blank? || target.nil?
    full  = target.full_name.to_s.strip
    first = full.split(/\s+/, 2).first.to_s
    last  = full.split(/\s+/, 2).last.to_s
    cleaned = reason.dup
    [full, "#{first} #{last}", first, last].uniq.reject(&:blank?).each do |name|
      cleaned = cleaned.gsub(/#{CONNECTOR_RE.source}\s+#{Regexp.escape(name)}\b/i, "")
    end
    [full, "#{first} #{last}", first, last].uniq.reject(&:blank?).each do |name|
      cleaned = cleaned.gsub(/\b#{Regexp.escape(name)}\b/i, "")
    end
    cleaned = cleaned.gsub(/\s+/, " ").strip
    cleaned = cleaned.sub(/^,\s*/, "").gsub(/\s+,/, ",").gsub(/,\s*,/, ",")
    cleaned = cleaned.sub(/#{CONNECTOR_RE.source}\s*[,.]?\s*$/i, "").strip
    cleaned = cleaned.sub(/^[,.\s]+/, "").sub(/[,\s]+$/, "")
    cleaned
  end

  def resolve_clinician_for_role(role)
    by_assignment = case role
                    when "rn"            then @patient.assigned_rn
                    when "md"            then @patient.assigned_md
                    when "sw","social_worker" then @patient.assigned_sw
                    when "chaplain"      then @patient.assigned_chaplain
                    end
    return by_assignment if by_assignment
    base = User.where(agency_id: @agency.id, active: true, family_access: false)
               .joins(user_roles: :role)
               .where(roles: { name: role == "social_worker" ? "social_worker" : role })
    base = base.where(branch_id: @patient.branch_id) if @patient.branch_id
    base.first
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
