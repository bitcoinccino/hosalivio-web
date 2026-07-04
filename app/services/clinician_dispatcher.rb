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
  # HCPCS Level II code: one letter + 4 digits (e.g. Q5001, J1234, E0250).
  HCPCS_RE   = /\b([A-Za-z]\d{4})\b/

  # Ordered keyword → intent map. First match wins. Loose matching on
  # purpose: clinicians type quickly and won't quote the menu.
  INTENT_MAP = [
    [ /\b(?:start|run|begin|do|open|new|create|generate)\b[^.\n]{0,25}\bprior[\s-]?auth/i, :start_prior_auth ],
    [ /\bprior[\s-]?auth(?:orization)?\b[^.\n]{0,25}\breview\b/i,                          :start_prior_auth ],
    [ /\b(comfort\s*kit|comfort-kit)\b/i,                       :pharmacy_comfort_kit ],
    [ /\b(refill|out\s*of|running\s*low|need\s*more)\b/i,       :pharmacy_refill ],
    [ /\b(chaplain|spiritual)\b/i,                              :chaplain_request ],
    [ /\b(social\s*work(er)?|psychosocial)\b/i,                 :sw_request ],
    [ /\b(dme|equipment|hospital\s*bed|wheelchair|walker|oxygen|commode)\b/i, :dme_order ],
    [ /\b(verify|check|confirm|review)\b.{0,40}\b(insurance|coverage|benefits?|medicare|medicaid|eligibility)\b/i, :verify_insurance ],
    [ /\b(insurance|coverage|benefits?|medicare|medicaid|eligibility)\b.{0,40}\b(verify|check|confirm|review)\b/i, :verify_insurance ],
    [ /\b(noe|notice\s*of\s*election|insurance\s*file)\b/i,     :noe_file ]
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
  def self.execute(note:, requester:, action:, ack: nil, notify: nil)
    return Result.new(dispatched: false, reason: "no_action") if action.blank? || action == "no_action"
    d = new(note, requester)
    intent = action.to_sym
    case intent
    when :notify_clinician
      d.send(:dispatch_clinician_relay, notify)
    when :confirm_relay
      d.send(:confirm_pending_relay, notify)
    when :cancel_relay
      d.send(:cancel_pending_relay)
    when :start_prior_auth
      d.send(:dispatch_prior_auth, ack: ack)
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

  # A "where do things stand" ask. Routed to answer_question even when the LLM
  # classifier is down (returns no_action), because answer_question can fall
  # back to a deterministic chart summary.
  SUMMARY_RE = /\b(?:summar(?:y|ize|ise|ies)|status|catch (?:me )?up|where are we|what'?s going on|going on with|update on|brief me|overview|recap|sum up|how'?s? (?:\w+ )?doing)\b/i

  def self.summary_question?(body)
    SUMMARY_RE.match?(body.to_s)
  end

  # A direct @HosAlivio message that classification couldn't turn into an
  # action (vague ask, unsupported relay target, plain chit-chat). Post a
  # short ack so a direct delegation never vanishes without a reply. No-op
  # (returns false) when HosAlivio wasn't actually @-mentioned — an action-
  # verb message with no mention shouldn't get an unsolicited bot reply.
  # `ack` is the optional conversational reply the brain already drafted;
  # we prefer it over the generic fallback when present.
  def self.acknowledge_unactionable(note:, requester:, ack: nil)
    return false unless mentions_hosalivio?(note.body)
    new(note, requester).send(:post_unactionable_ack, ack)
    true
  end

  # Short yes/no the clinician types to answer a pending relay preview.
  RELAY_AFFIRMATIVE_RE = /\A\s*(?:@hosalivio\b[\s,:-]*)?(yes|yep|yeah|yup|ok|okay|sure|send( it)?|do it|please|confirm(ed)?|go ahead)\b[\s.!]*\z/i
  RELAY_NEGATIVE_RE    = /\A\s*(?:@hosalivio\b[\s,:-]*)?(no|nope|cancel|don'?t|do not|stop|never\s*mind|nvm|hold off|wait)\b[\s.!]*\z/i

  # The most recent HosAlivio message for this patient that is a drafted-
  # but-unsent relay offer, or nil. If the latest HosAlivio note is
  # anything else (an ack, an answer), the offer is considered resolved.
  def self.pending_relay_offer(patient)
    latest_ai = patient.notes.order(created_at: :desc).limit(15).detect(&:ai_authored?)
    return nil unless latest_ai&.audit_kind == :hosalivio_offer
    latest_ai
  end

  def self.pending_relay_offer?(patient)
    pending_relay_offer(patient).present?
  end

  # When a clinician message is a bare yes/no AND a relay preview is
  # pending for this patient, returns :confirm_relay / :cancel_relay so the
  # job can dispatch deterministically without an LLM round-trip. Returns
  # nil otherwise (normal classification continues).
  def self.relay_confirmation_for(note)
    body = note.body.to_s
    return nil unless body.match?(RELAY_AFFIRMATIVE_RE) || body.match?(RELAY_NEGATIVE_RE)
    return nil unless pending_relay_offer?(note.patient)
    body.match?(RELAY_AFFIRMATIVE_RE) ? :confirm_relay : :cancel_relay
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
    # "What can you do? / who are you?" is a fixed answer — skip the LLM and
    # post a short, scannable capability blurb instead of a verbose paragraph.
    if capability_question?(@note.body)
      post_answer(capability_blurb)
      return Result.new(dispatched: true, intent: "capability_answer")
    end

    role = (@requester.role_names & %w[rn md don admissions admin aide sw social_worker chaplain]).first || "rn"
    result = HosalivioBrain.answer_clinician_question(
      question:       @note.body.to_s,
      patient:        @patient,
      role:           role,
      thread_context: recent_clinician_thread_context
    )

    if result
      post_answer(result["answer"])
      # Same notify-on-acceptance path as the family side: when the
      # clinician confirms an offer ("yes, ping admissions") the
      # brain returns a notify directive, which we execute as a
      # clinician_only urgent note that @-mentions the right human.
      if (notify = result["notify"])
        execute_notify_directive(notify)
      end
      # Proactive offer: the brain wants to ping a teammate. Post a Send/Cancel
      # offer pill (same one the imperative relay uses) so the clinician acts
      # with one tap instead of typing "yes".
      if (offer = result["offer"])
        post_ping_offer(offer["role"], offer["message"])
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
    elsif self.class.summary_question?(@note.body)
      # The brain is down, but a status/summary ask can still be answered from
      # the chart deterministically — better than an apology during an outage.
      post_answer(PatientStatusSummary.call(patient: @patient, role: role))
    else
      post_answer(fallback_answer_for(role))
    end
    Result.new(dispatched: true, intent: "answer_question")
  end

  # A bare "what can you do / who are you" question (the WHOLE message, so a
  # clinical question like "what can you do about her pain?" is NOT caught).
  CAPABILITY_RE = /\A\s*(?:@?hosalivio[\s,]*)?(?:what (?:can|do) you (?:do|help(?: me)?(?: with)?|offer)|how (?:can|do) you help(?: me)?|who are you|what are you|what(?:'s| is) hosalivio|what(?:'s| is) your (?:job|role|purpose)|introduce yourself)\??\s*\z/i

  def capability_question?(body)
    CAPABILITY_RE.match?(body.to_s)
  end

  # Short, scannable capability blurb — leadership-friendly, no corporate
  # paragraph. Ends with an offer naming the patient.
  def capability_blurb
    first = @patient&.first_name.to_s.strip
    whom  = first.present? ? " for #{first}" : ""
    <<~MSG.strip
      I'm HosAlivio, your AI care-coordination assistant.

      I mainly help with:
      - Patient status, visit progress, and open documentation blockers
      - Summarizing recent visits
      - Flagging missing items (consents, unsigned docs)
      - Routing messages to the right team member

      I don't give clinical advice or make care decisions, I'll always point those to you or the clinical team.

      What would you like help with#{whom}?
    MSG
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

  # notify_clinician action: the clinician asked HosAlivio to relay a
  # concrete message to a named teammate ("let the MD know the admission
  # is almost completed"). We DON'T send right away. Sending an internal
  # message is a clinical/operational action, so we draft it, show a
  # preview naming the resolved teammate, and wait for the clinician to
  # confirm. The drafted message + resolved target are stored in the
  # offer note's payload so the confirm step sends exactly what was
  # previewed — no second LLM pass, no drift.
  def dispatch_clinician_relay(notify)
    notify = notify.is_a?(Hash) ? notify : {}
    role   = (notify["role"] || notify[:role]).to_s.strip.downcase
    reason = (notify["reason"] || notify[:reason]).to_s.strip

    # "Let the family know …" — relay an update to the patient's family rather
    # than a teammate. Same draft→preview→confirm flow, but the confirmed
    # message is posted family-visible (see confirm_family_relay). HosAlivio
    # has already drafted a warm, family-appropriate message in `reason`.
    if role == "family"
      if reason.empty?
        post_ack("I caught that you want to update the family, but not what to say. Try \"@HosAlivio let the family know the comfort kit is on the way.\"")
        return Result.new(dispatched: false, reason: "family_relay_incomplete", intent: "relay_to_family")
      end
      posted = post_family_relay_offer(reason)
      return Result.new(dispatched: posted, intent: posted ? "relay_to_family_offer" : "family_relay_error")
    end

    if role.empty? || reason.empty?
      post_ack("I caught that you want to flag a teammate, but not who or what. Try \"let the MD know the admission is almost done.\"")
      return Result.new(dispatched: false, reason: "notify_clinician_incomplete", intent: "notify_clinician")
    end

    posted = post_ping_offer(role, reason)
    Result.new(dispatched: posted, intent: posted ? "notify_clinician_offer" : "no_clinician_for_role:#{role}")
  rescue => e
    Rails.logger.warn("[ClinicianDispatcher#dispatch_clinician_relay] #{e.class}: #{e.message}")
    post_ack("I hit a snag drafting that. Mind trying again, or tag the teammate directly?")
    Result.new(dispatched: false, reason: "relay_error", intent: "notify_clinician")
  end

  # The clinician answered a pending relay offer with "yes". Decode the
  # latest unsent offer for this patient and deliver it verbatim.
  # override may carry { "message" => "<edited text>" } when the clinician
  # tweaked the draft via the Edit affordance before sending.
  def confirm_pending_relay(override = nil)
    offer   = self.class.pending_relay_offer(@patient)
    payload = offer&.offer_payload
    unless payload
      post_ack("I don't have a drafted message waiting, so there's nothing to send. Tell me what to pass along and to whom.")
      return Result.new(dispatched: false, reason: "no_pending_offer", intent: "confirm_relay")
    end
    return confirm_prior_auth(payload)          if payload["kind"] == "prior_auth"
    return confirm_family_relay(payload, override) if payload["target"] == "family"
    role    = payload["role"].to_s
    target  = User.where(agency_id: @agency.id).find_by(id: payload["target_user_id"]) ||
              resolve_clinician_for_role(role)
    edited  = override.is_a?(Hash) ? override["message"].to_s.strip : nil
    message = edited.presence || payload["message"].to_s
    # Scrub the target's name (the @-mention is added at send time) — covers
    # an edited message where the clinician typed the name back in.
    message = scrub_clinician_name_from_reason(message, target).presence || message if target
    unless target && message.present?
      post_ack("That draft expired or the teammate is no longer reachable. Want me to draft it again?")
      return Result.new(dispatched: false, reason: "offer_unresolvable", intent: "confirm_relay")
    end
    deliver_relay(role: role, target: target, message: message)
    post_ack("Sent to #{target.full_name} (#{relay_role_label(role)}). It's in their queue now.")
    Result.new(dispatched: true, intent: "confirm_relay")
  end

  # The clinician declined a pending relay offer ("no" / "cancel").
  def cancel_pending_relay
    offer   = self.class.pending_relay_offer(@patient)
    payload = offer&.offer_payload
    if payload && payload["kind"] == "prior_auth"
      post_ack("Okay, I won't start that prior-auth review. Nothing was generated.")
      return Result.new(dispatched: true, intent: "cancel_relay")
    end
    if payload && (target = User.where(agency_id: @agency.id).find_by(id: payload["target_user_id"]))
      post_ack("Okay, I won't send that to #{target.full_name}. Nothing went out.")
    else
      post_ack("Okay, I won't send that. Nothing went out.")
    end
    Result.new(dispatched: true, intent: "cancel_relay")
  end

  # ── Prior-authorization review (offer → confirm, reusing the relay pattern) ──

  # "@HosAlivio start a prior auth for Q5001". Reviewer-gated. If a HCPCS code is
  # in the message, post a Send/Cancel offer; otherwise nudge with the form link.
  def dispatch_prior_auth(ack: nil)
    unless (@requester.role_names & PriorAuthReviewsController::REVIEWER_ROLES).any?
      post_ack("Prior-auth reviews are handled by admin, DON, MD, insurance, or billing — ask one of them to start it for #{@patient.first_name}.")
      return Result.new(dispatched: false, reason: "not_reviewer", intent: "start_prior_auth")
    end

    hcpcs = @note.body.to_s[HCPCS_RE, 1]&.upcase
    if hcpcs
      posted = post_prior_auth_offer(hcpcs)
      Result.new(dispatched: posted, intent: "start_prior_auth_offer")
    else
      path = Rails.application.routes.url_helpers.new_prior_auth_review_path(patient_id: @patient.id)
      post_ack("I can start a prior-authorization review — I just need the procedure code. Reply with it (e.g. \"@HosAlivio start a prior auth for Q5001\") or open the form: #{path}")
      Result.new(dispatched: true, intent: "start_prior_auth_prompt")
    end
  end

  # Drafted-but-unrun offer. Same offer-note shape as a relay (HOSALIVIO_OFFER
  # prefix + base64 payload) so the chat renders Send/Cancel and confirm_relay
  # routes back here via the "prior_auth" payload kind.
  def post_prior_auth_offer(hcpcs)
    payload = { "kind" => "prior_auth", "procedure_hcpcs" => hcpcs }
    preview = "Want me to start a prior-authorization review for HCPCS #{hcpcs}? I'll read the documents on #{@patient.first_name}'s chart and draft a recommendation for your sign-off."
    Note.create!(
      agency:         @agency,
      patient:        @patient,
      parent_note:    reply_anchor,
      author_role:    "admissions",
      body:           "#{Note::HOSALIVIO_OFFER_PREFIX}#{Base64.strict_encode64(payload.to_json)}\n#{preview}",
      urgency:        "normal",
      source:         "system",
      clinician_only: true
    )
    true
  rescue ActiveRecord::RecordInvalid
    false
  end

  # Confirmed: extract the chart's documents (Stage 0), run the pipeline via
  # ReviewAssembler, and post a link to the generated review. Never raises.
  def confirm_prior_auth(payload)
    hcpcs = payload["procedure_hcpcs"].to_s
    review = ActsAsTenant.with_tenant(@agency) do
      next nil unless CoveragePolicy.for_hcpcs(hcpcs)
      doc_texts = @patient.patient_documents.with_attached_file.map { |d| PriorAuth::DocumentExtractor.call(d) }
      PriorAuth::ReviewAssembler.call(
        patient:         @patient,
        procedure_hcpcs: hcpcs,
        provider_npi:    @patient.intake["attending_physician_npi"],
        document_texts:  doc_texts
      )
    end

    unless review
      post_ack("There's no active Medicare policy for HCPCS #{hcpcs}, so I couldn't start the review — double-check the code?")
      return Result.new(dispatched: false, reason: "no_policy", intent: "start_prior_auth")
    end

    path = Rails.application.routes.url_helpers.prior_auth_review_path(review)
    post_ack("Prior-auth review ready for HCPCS #{hcpcs} — recommendation: #{review.recommendation.humanize}. Open it: #{path}")
    Result.new(dispatched: true, intent: "start_prior_auth")
  rescue => e
    Rails.logger.warn("[ClinicianDispatcher#confirm_prior_auth] #{e.class}: #{e.message}")
    post_ack("I hit a snag generating that review. You can start it from Quick actions → Prior-auth review.")
    Result.new(dispatched: false, reason: "prior_auth_error", intent: "start_prior_auth")
  end

  # Draft-but-unsent offer to update the FAMILY. Clinician-only and top-level
  # (parent_note nil) so it never inherits a family thread's visibility — only
  # the clinician sees the draft + Send/Edit/Cancel. The payload marks the
  # target "family" and stashes the family thread root so the confirmed message
  # threads under the family's conversation. Shared by the clinician relay
  # ("@HosAlivio let the family know …") and the family-triage hybrid gate
  # (HosalivioTriager holds a promised commitment for review).
  def self.post_family_relay_offer(agency:, patient:, message:, family_thread_id: nil, preview_lead: "Here's what I'll send to the family:")
    message = message.to_s.strip
    return nil if message.empty?
    payload = { "target" => "family", "message" => message, "family_thread_id" => family_thread_id }
    note = Note.create!(
      agency:         agency,
      patient:        patient,
      parent_note:    nil,
      author_role:    "admissions",
      body:           "#{Note::HOSALIVIO_OFFER_PREFIX}#{Base64.strict_encode64(payload.to_json)}\n#{preview_lead}\n\n\"#{message}\"",
      urgency:        "normal",
      source:         "system",
      clinician_only: true
    )
    notify_assigned_rn_of_offer(note: note, patient: patient, agency: agency)
    note
  rescue ActiveRecord::RecordInvalid
    nil
  end

  # Nudge the patient's responsible nurse that a family-facing draft is waiting
  # for their Send — otherwise a held commitment only surfaces if they happen to
  # open this patient's chat. In-app bell only (relay_offer_pending is suppressed
  # from outbound pings); clicking deep-links to the draft in the patient chat.
  # Targets the ongoing Primary/Visit RN, falling back to the Admission RN.
  def self.notify_assigned_rn_of_offer(note:, patient:, agency:)
    rn = patient.assigned_visit_rn || patient.assigned_rn
    return unless rn
    Notification.create!(
      agency: agency,
      user:   rn,
      kind:   "relay_offer_pending",
      title:  "Draft reply awaiting your Send — #{patient.first_name}",
      body:   "HosAlivio drafted a family update that needs your review before it goes out.",
      linked: note
    )
  rescue => e
    Rails.logger.warn("[ClinicianDispatcher.notify_assigned_rn_of_offer] #{e.class}: #{e.message}")
  end

  def post_family_relay_offer(message)
    self.class.post_family_relay_offer(
      agency: @agency, patient: @patient, message: message,
      family_thread_id: @note.parent_note_id
    ).present?
  end

  # The clinician confirmed a family-relay offer. Deliver the (possibly edited)
  # message into the family-visible thread and notify the family.
  def confirm_family_relay(payload, override = nil)
    edited  = override.is_a?(Hash) ? override["message"].to_s.strip : nil
    message = (edited.presence || payload["message"].to_s).strip
    if message.empty?
      post_ack("That draft expired. Tell me what to pass along and I'll redraft it.")
      return Result.new(dispatched: false, reason: "offer_unresolvable", intent: "confirm_relay")
    end
    delivered = deliver_family_relay(message, payload["family_thread_id"])
    if delivered
      post_ack("Sent to the family. They've been notified.")
      Result.new(dispatched: true, intent: "confirm_relay")
    else
      post_ack("I hit a snag sending that to the family. Mind trying again?")
      Result.new(dispatched: false, reason: "family_relay_send_failed", intent: "confirm_relay")
    end
  end

  # Post the confirmed update into the family-visible thread (family sees it +
  # gets a bell). Authored as a system/HosAlivio note so it renders as a warm
  # care-team message in the family chat (broadcasts via the Note callback).
  def deliver_family_relay(message, family_thread_id)
    root = family_thread_id.present? ? @patient.notes.find_by(id: family_thread_id) : nil
    note = Note.create!(
      agency:         @agency,
      patient:        @patient,
      parent_note:    root,
      author_role:    "admissions",
      body:           message,
      urgency:        "normal",
      source:         "system",
      clinician_only: false
    )
    User.where(agency_id: @agency.id, patient_id: @patient.id, family_access: true, active: true).find_each do |fam|
      Notification.create!(
        agency: @agency, user: fam, kind: "mentioned",
        title:  "Update from #{@patient.first_name}'s care team",
        body:   message.to_s.truncate(140),
        linked: note
      )
    end
    note
  rescue => e
    Rails.logger.warn("[ClinicianDispatcher#deliver_family_relay] #{e.class}: #{e.message}")
    nil
  end

  # Resolve a role to its assigned clinician and post a Send/Cancel offer
  # pill carrying `message`. Shared by the imperative relay ("let the MD
  # know …") and the Q&A proactive offer ("Want me to flag the DON?").
  # Returns true if an offer pill was posted, false (with a soft ack) when
  # the role can't be resolved to a human.
  def post_ping_offer(role, message)
    role    = role.to_s.strip.downcase
    message = message.to_s.strip
    return false if role.empty? || message.empty?

    label  = relay_role_label(role)
    target = resolve_clinician_for_role(role)
    unless target
      post_ack("I don't see an assigned #{label} on this patient yet, so I couldn't flag them. Want me to route it another way?")
      return false
    end
    # Strip the target's name so the @-mention added at send time isn't doubled.
    clean = scrub_clinician_name_from_reason(message, target).presence || message
    post_relay_offer(role: role, target: target, label: label, message: clean)
    true
  end

  # Posts the drafted-but-unsent relay preview. The marker line stores the
  # payload (base64 JSON) so confirm_pending_relay can deliver it exactly.
  def post_relay_offer(role:, target:, label:, message:)
    payload = { "role" => role, "target_user_id" => target.id, "message" => message }
    # No "reply yes/cancel" line — the chat renders Send/Cancel buttons.
    # Typing yes/cancel still works as a keyboard fallback.
    preview = "Here's what I'll send #{target.full_name} (#{label}):\n\n\"#{message}\""
    Note.create!(
      agency:         @agency,
      patient:        @patient,
      parent_note:    reply_anchor,
      author_role:    "admissions",
      body:           "#{Note::HOSALIVIO_OFFER_PREFIX}#{Base64.strict_encode64(payload.to_json)}\n#{preview}",
      urgency:        "normal",
      source:         "system",
      clinician_only: true
    )
  rescue ActiveRecord::RecordInvalid
    nil
  end

  # Actually delivers a confirmed relay: the @-mention note in the chart +
  # a bell notification + an audit event. Shared by the confirm path.
  def deliver_relay(role:, target:, message:)
    Current.agency           ||= @agency
    Current.agent_id         ||= "admissions"
    Current.agent_session_id ||= "hosalivio-dispatch-#{SecureRandom.hex(4)}"
    first = target.full_name.to_s.split(/\s+/, 2).first.presence || "team"
    note  = Note.create!(
      agency:         @agency,
      patient:        @patient,
      author_role:    "admissions",
      body:           "@#{first} #{message}",
      urgency:        "normal",
      source:         "system",
      clinician_only: true
    )
    Notification.create!(
      agency: @agency,
      user:   target,
      kind:   "mentioned",
      title:  "Message from #{@requester&.full_name.presence || 'the care team'}",
      body:   "#{@patient.full_name}: #{message}",
      linked: note
    )
    AgentEvent.create!(
      agency:           @agency,
      agent_id:         "admissions",
      agent_session_id: Current.agent_session_id,
      action:           "notify_clinician",
      subject:          @patient,
      change_set:       { target_role: role, target_user_id: target.id,
                          message: message, requested_by: @requester&.full_name },
      happened_at:      Time.current
    )
    note
  end

  # Human-readable label for a relay target role (handles the sw alias).
  def relay_role_label(role)
    key = role == "sw" ? "social_worker" : role
    HosalivioTriager::ROLE_LABELS[key] || key.titleize
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
    [ full, "#{first} #{last}", first, last ].uniq.reject(&:blank?).each do |name|
      cleaned = cleaned.gsub(/#{CONNECTOR_RE.source}\s+#{Regexp.escape(name)}\b/i, "")
    end
    [ full, "#{first} #{last}", first, last ].uniq.reject(&:blank?).each do |name|
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
    when "visit_rn"      then @patient.assigned_visit_rn || @patient.assigned_rn  # fall back to admission RN
    when "md"            then @patient.assigned_md
    when "sw", "social_worker" then @patient.assigned_sw
    when "chaplain"      then @patient.assigned_chaplain
    end
    return by_assignment if by_assignment
    base = User.where(agency_id: @agency.id, active: true, family_access: false)
               .joins(user_roles: :role)
               .where(roles: { name: role == "social_worker" ? "social_worker" : role })
    base = base.where(branch_id: @patient.branch_id) if @patient.branch_id
    base.first
  end

  # Soft ack for a direct @HosAlivio mention we couldn't action. Prefer the
  # brain's own conversational reply; otherwise a generic nudge that names
  # what HosAlivio can actually do, so the clinician isn't left guessing.
  def post_unactionable_ack(ack = nil)
    text = ack.to_s.strip.presence ||
      "I saw your note, but I couldn't tell what you'd like me to do. I can pass a message to the MD, RN, or DON (\"let the RN know …\"), or answer a question about this patient. What would you like?"
    post_ack(text)
  end

  # Posts a short HosAlivio reply into the team-only audit trail so
  # the requester sees the dispatch confirmed inline.
  def post_ack(text)
    post_hosalivio_note(Note::HOSALIVIO_ACK_PREFIX, text)
  end

  # A HosAlivio answer to a clinician question. Same pill as an ack, but the
  # [HOSALIVIO_ANSWER] prefix marks it reply-able so follow-ups thread under
  # it — dispatch confirmations (post_ack) stay non-reply-able.
  def post_answer(text)
    post_hosalivio_note(Note::HOSALIVIO_ANSWER_PREFIX, text)
  end

  def post_hosalivio_note(prefix, text)
    Note.create!(
      agency:         @agency,
      patient:        @patient,
      # When @HosAlivio was invoked inside a thread, thread the answer under
      # that conversation's root (nil otherwise → normal top-level note).
      parent_note:    reply_anchor,
      author_role:    "admissions",
      # The prefix triggers the bot-avatar pill renderer in the chat partial +
      # Cable JS. Stripped before display.
      body:           "#{prefix} #{text}",
      urgency:        "normal",
      source:         "system",
      clinician_only: true
    )
  rescue ActiveRecord::RecordInvalid
    nil
  end

  # The root of @note's thread, or nil when @note isn't itself a reply.
  # Replies are one level deep, so a reply's parent IS the root.
  def reply_anchor
    return nil unless @note.parent_note_id
    root = @note.parent_note
    # Don't thread HosAlivio's clinician-facing acks/offers under a family-
    # visible root — they'd inherit family visibility. Keep them top-level and
    # team-only. The explicit family relay (deliver_family_relay) is the only
    # thing that posts into the family thread.
    return nil unless root&.clinician_only
    root
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
