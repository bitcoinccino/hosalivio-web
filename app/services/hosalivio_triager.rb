# HosalivioTriager — the action-taker behind the family chat.
#
# Delegates classification + reply composition to HosalivioBrain. Its
# own job is stateful: create notes, emit agent events, mark inbound
# messages as handled. No decisions made here.
#
# Contract: HosalivioBrain returns { intent, urgency, reasoning, reply, source }.
# This class maps intent -> which roles to ping, then executes.

class HosalivioTriager
  # Escalation routing by intent. URGENCY comes from HosalivioBrain (context-aware);
  # this table only decides WHO gets pinged for each category.
  ESCALATION_ROLES = {
    # Family chat is ongoing care, so the nurse target is the VISIT (Primary)
    # nurse, not the admission RN. resolve_clinician_for_role falls back to the
    # admission RN when no visit nurse is assigned yet.
    "pain_crisis"        => %w[visit_rn md],
    "dyspnea"            => %w[visit_rn md],
    "decline"            => %w[visit_rn],
    "caregiver_distress" => %w[social_worker chaplain],
    # MD included: someone actively dying needs the physician, not only the
    # nurse and chaplain — comfort orders and pronouncement both run through
    # them. Added 2026-07-17 after lib/eval surfaced that the taxonomy had no
    # home for acute deterioration that isn't pain or dyspnea: the only intent
    # that paged an MD was pain_crisis, so "grey, clammy, unresponsive" had to
    # be mislabelled as pain to reach a doctor. See lib/eval/README.md.
    "transitioning"      => %w[visit_rn chaplain md],
    "med_refill"         => %w[pharmacy visit_rn],
    "callback_request"   => %w[visit_rn],
    "spiritual"          => %w[chaplain social_worker],
    "logistics"          => %w[dme visit_rn],
    "status_question"    => %w[visit_rn],
    "other"              => %w[visit_rn]
  }.freeze

  # Human-readable labels used in audit-trace bodies. Avoids exposing the
  # snake_case enum keys ("med_refill", "pain_crisis") to clinicians.
  INTENT_LABELS = {
    "pain_crisis"        => "Pain crisis",
    "dyspnea"            => "Breathing difficulty",
    "decline"            => "Patient declining",
    "caregiver_distress" => "Caregiver distress",
    "transitioning"      => "End-of-life transition",
    "med_refill"         => "Medication refill",
    "callback_request"   => "Callback request",
    "spiritual"          => "Spiritual support",
    "logistics"          => "Logistics request",
    "status_question"    => "Status check",
    "other"              => "General message"
  }.freeze

  ROLE_LABELS = {
    "rn"            => "Admission Nurse",
    "visit_rn"      => "Visit Nurse",
    "md"            => "Admitting Physician",
    "social_worker" => "Social Worker",
    "chaplain"     => "Chaplain",
    "pharmacy"      => "Pharmacy",
    "dme"           => "DME",
    "insurance"     => "Insurance",
    "aide"          => "Care Assistant",
    "lpn"           => "Support Nurse",
    "don"           => "Scheduling Coordinator",
    "admissions"    => "Admissions"
  }.freeze

  # Run one pass over every agency, triaging any unread family notes.
  # Useful for cron; day-to-day triage runs inline via HosalivioTriageJob.
  def self.tick
    count = 0
    Agency.find_each do |agency|
      ActsAsTenant.with_tenant(agency) do
        Note.where(author_role: "family", read_at: nil).order(:created_at).each do |note|
          new(note).triage!
          count += 1
        end
      end
    end
    count
  end

  def initialize(note)
    @note    = note
    @patient = note.patient
    @agency  = note.agency
  end

  # If a real clinician replied to this patient in the last N minutes, the
  # AI should stay out of the conversation. Carlos saying "thank you" to
  # Pascal's "I'm on my way" message shouldn't kick the brain into a fresh
  # triage chain.
  HUMAN_CONVERSATION_WINDOW = 30.minutes

  INTERROGATIVES = %w[who what when where why how is has does can should will which are who's what's].freeze
  AFFIRMATIVES   = %w[yes yeah yep yup ok okay sure please correct right confirm].freeze
  CONTEXT_REPLY_MAX_WORDS = 6

  def looks_like_question?(body)
    s = body.to_s.strip
    return false if s.empty?
    return true if s.end_with?("?")
    first = s.split(/\s+/, 2).first.to_s.downcase.gsub(/[[:punct:]]+$/, "")
    INTERROGATIVES.include?(first)
  end

  # True when the body is a short reply (≤ 6 words) that's most
  # likely a continuation of a prior HosAlivio offer / question.
  # Routes "yes", "ok please", "do it" through the context-aware
  # answer path so the brain can use thread context to interpret
  # them, instead of the generic triage path which sees them in
  # isolation and produces "I don't understand" replies.
  def context_reply?(body)
    s = body.to_s.strip
    words = s.split(/\s+/)
    return false if words.empty? || words.length > CONTEXT_REPLY_MAX_WORDS
    first = words.first.to_s.downcase.gsub(/[[:punct:]]+$/, "")
    return true if AFFIRMATIVES.include?(first)
    return true if %w[no nope thanks thank].include?(first)
    # Has a recent HosAlivio reply in the thread (within 30 min)?
    @patient.notes
            .where(author_role: "admissions", source: "system")
            .where("created_at > ?", 30.minutes.ago)
            .exists?
  end

  GRATITUDE_RE = /\b(?:thank(?:s| ?you| ?u)?|thx|thanx|ty|appreciate(?:d| it)?|grateful)\b/i
  # A real request riding alongside the thanks ("thanks, can you send…") must
  # still be triaged, not closed out with a "you're welcome".
  NEED_RE = /\b(?:can|could|when|where|why|how|need|send|call|schedule|refill|order|come|coming|visit|deliver|fix|out of|running low)\b/i

  # A pure social closer: short, no question, expresses gratitude, and carries no
  # actionable request. These get a warm acknowledgment instead of being fed to
  # the Q&A brain (which has nothing to answer and falls back to an apology).
  def pleasantry?(body)
    s = body.to_s.strip
    return false if s.empty? || s.include?("?")
    return false if s.split(/\s+/).length > 6
    s.match?(GRATITUDE_RE) && !s.match?(NEED_RE)
  end

  # Phrases that mark a HosAlivio turn as an OFFER awaiting a yes/no.
  OFFER_CUES = [
    /\bwould you like\b/i, /\bwant me to\b/i, /\bshall i\b/i, /\bshould i\b/i,
    /\bdo you want me\b/i, /\bi can (?:flag|let|reach|notify|connect|pass|loop|ask)\b/i,
    /\blet me know if\b/i
  ].freeze

  # True when an outgoing HosAlivio reply offers to do something and awaits a
  # yes/no. Evaluated once when the reply is posted and persisted on the note
  # (family_offer), so detection doesn't depend on re-parsing prose later.
  def offer_reply?(text)
    s = text.to_s
    s.include?("?") && OFFER_CUES.any? { |re| s.match?(re) }
  end

  # True when the immediately-preceding family-visible message was a HosAlivio
  # offer awaiting a reply. Trusts the persisted family_offer marker first; falls
  # back to the body heuristic only for notes posted before the marker existed.
  def pending_family_offer?
    last = @patient.notes
                   .where(clinician_only: [ nil, false ])
                   .where.not(id: @note.id)
                   .order(created_at: :desc).first
    return false unless last&.ai_authored?
    return true if last.family_offer?
    offer_reply?(last.body)
  end

  # Cues that a longer message is RESPONDING to a pending offer (deciding it),
  # not raising a brand-new topic.
  RESPONSE_CUES = /\b(?:no|nope|thanks|thank you|go ahead|do it|do that|please do|flag|notify|let (?:them|him|her) know|reach out|contact|connect)\b/i

  # Route a reply to the context-aware path when there's a pending offer AND the
  # message reads as a response to it — short, or carrying an affirmative/
  # negative/directive cue anywhere (so "Flag the right person for me, please."
  # is recognized as a yes even though it's 7 words and doesn't start with one).
  # Genuinely new topics fall through to the triage path (which now also has
  # conversation memory), so escalations/handoffs aren't skipped.
  def responds_to_pending_offer?
    return false unless pending_family_offer?
    s = @note.body.to_s.strip
    return true if s.split(/\s+/).length <= CONTEXT_REPLY_MAX_WORDS
    AFFIRMATIVES.any? { |w| s.match?(/\b#{Regexp.escape(w)}\b/i) } || s.match?(RESPONSE_CUES)
  end

  def triage!
    # 0 — SUPPRESS if a human clinician is actively in this thread
    if human_clinician_recently_active? && !@note.urgency_crisis?
      Rails.logger.info("[HosalivioTriager] suppressing AI — human clinician active in thread for patient=#{@patient.id}")
      @note.mark_read!
      return
    end

    # 0.4 — PURE PLEASANTRY (a thank-you / sign-off with no question and no
    # pending offer to decide). Acknowledge warmly and stop — don't feed it to
    # the Q&A brain, which has nothing to answer and falls back to an apologetic
    # "I've nudged the team" that also isn't true.
    if !@note.urgency_crisis? && !pending_family_offer? && pleasantry?(@note.body)
      acknowledge_pleasantry!
      return
    end

    # 0.5 — Context-aware short-circuit. Either (a) a question worth
    # answering directly, or (b) a short reply ("yes", "thanks") that
    # only makes sense in the context of HosAlivio's prior turn.
    # Both routes go through answer_family! which feeds the thread
    # context to the brain. Crisis messages still use the normal
    # triage below because they need handoffs even when phrased
    # conversationally.
    if !@note.urgency_crisis? && (looks_like_question?(@note.body) || context_reply?(@note.body) || responds_to_pending_offer?)
      answer_family!
      return
    end

    # 1 — ASK THE BRAIN (never raises; returns fallback on failure). Pass the
    #     recent conversation so the generic triage path also has memory of the
    #     prior turns (e.g. an offer HosAlivio just made), not just this message.
    decision = HosalivioBrain.call(note: @note, thread_context: recent_thread_context)
    roles    = ESCALATION_ROLES.fetch(decision[:intent], ESCALATION_ROLES["other"])

    # Stamp Current so AgentAuditable attributes every write to HosAlivio's session.
    Current.agency           = @agency
    Current.agent_id         = "triage"
    Current.agent_session_id = "hosalivio-#{brain_suffix(decision[:source])}-#{SecureRandom.hex(4)}"

    # 2 — INTERNAL TRIAGE NOTE (for clinicians; not family-facing)
    Note.create!(
      agency:         @agency,
      patient:        @patient,
      author_role:    "admissions",
      body:           internal_triage_body(decision, roles),
      urgency:        decision[:urgency],
      source:         "system",
      clinician_only: true
    )

    # 3 — HANDOFF EVENTS (one per target role; these surface on Mission Stage)
    roles.each { |role| emit_handoff(role, decision[:intent], decision[:urgency]) }

    # 4 — FAMILY-FACING ACK (auto-posted immediately; broadcasts via Note
    #     callback). The brain keeps this acknowledgment promise-free, so it's
    #     safe to send without review — the family gets fast empathy even on a
    #     pain/distress message. Threaded under the family's message so the
    #     question + HosAlivio's reply read as one conversation.
    Note.create!(
      agency:       @agency,
      patient:      @patient,
      parent_note:  thread_anchor,
      author_role:  "admissions",
      body:         decision[:reply],
      urgency:      "normal",     # reply itself is calm; urgency captured internally
      source:       "system",
      family_offer: offer_reply?(decision[:reply])
    )

    # 4.5 — COMMITMENT DRAFT (hybrid gate). If HosAlivio's response promised a
    #       concrete action (a refill, a callback, an equipment fix, a confirmed
    #       time), DON'T tell the family directly — hold it as a clinician-only
    #       Send/Edit/Cancel draft. A human confirms before the promise reaches
    #       the family (reuses the family-relay offer→confirm flow).
    if decision[:commitment].present?
      ClinicianDispatcher.post_family_relay_offer(
        agency:           @agency,
        patient:          @patient,
        message:          decision[:commitment],
        family_thread_id: thread_anchor&.id,
        preview_lead:     "Here's the follow-up I'd send the family:"
      )
    end

    # 5 — MARK INBOUND AS HANDLED (idempotent — triage! is safe to retry)
    @note.mark_read!
  ensure
    Current.reset
  end

  private

  # Where to thread HosAlivio's reply: under the conversation's ROOT note.
  # If the inbound is itself a reply (family followed up inside a thread),
  # anchor to its parent — replies are one level deep, so we can't nest under
  # a reply.
  def thread_anchor
    @note.thread_root? ? @note : @note.parent_note
  end

  # Timing/scheduling questions should never get the generic "tell me more"
  # fallback — that reads as evasive. When the brain returns nothing for one,
  # give a warm, honest answer that offers to check with the nurse. The "Would
  # you like me to do that?" makes it a pending offer, so a later "yes" is acted
  # on via responds_to_pending_offer?.
  SCHEDULING_Q = /\b(?:when|what time|how long|coming|arrive|arriving|arrives|on (?:her|his|the) way|schedule[d]?)\b/i

  def fallback_answer_for(body)
    if timing_question?(body)
      "I don't have the exact visit time in front of me right now, but I've let your nurse know you're asking and they'll reach out with an update."
    else
      "I want to make sure you get the right help — could you tell me a little more about what you need for #{@patient.first_name}?"
    end
  end

  def timing_question?(body)
    SCHEDULING_Q.match?(body.to_s)
  end

  # Dedupe: did we already flag the nurse about visit timing for this patient in
  # the last 2 hours? Keyed off an AgentEvent marker (plain columns) rather than
  # the note body, which is encrypted at rest and can't be matched in SQL — so
  # repeated "any update?" messages don't ping the nurse over and over.
  def recently_flagged_nurse_about_timing?
    AgentEvent.where(agency: @agency, action: "family_timing_inquiry", subject: @patient)
              .where("happened_at > ?", 2.hours.ago)
              .exists?
  end

  def record_timing_inquiry!
    AgentEvent.create!(agency: @agency, agent_id: "hosalivio_brain",
                       action: "family_timing_inquiry", subject: @patient,
                       happened_at: Time.current, change_set: {})
  end

  # Warm, commitment-free acknowledgment of a thank-you / sign-off. No Q&A,
  # no nudge, no handoff — just close the loop kindly, threaded under the
  # conversation.
  def acknowledge_pleasantry!
    Note.create!(
      agency:      @agency,
      patient:     @patient,
      parent_note: thread_anchor,
      author_role: "admissions",
      body:        "You're very welcome. We're always here for #{@patient.first_name} — just reach out any time.",
      urgency:     "normal",
      source:      "system"
    )
    @note.mark_read!
  end

  # Family Q&A path. Calls HosalivioBrain.answer_clinician_question with
  # role: "family" (which gates the patient context to lay-friendly,
  # no specific drug names/doses) and posts the answer as a normal,
  # family-visible HosAlivio reply. Audit-logged for compliance.
  def answer_family!
    Current.agency           = @agency
    Current.agent_id         = "triage"
    Current.agent_session_id = "hosalivio-family-qa-#{SecureRandom.hex(4)}"

    result = HosalivioBrain.answer_clinician_question(
      question:       @note.body.to_s,
      patient:        @patient,
      role:           "family",
      thread_context: recent_thread_context
    )
    reply_text = result&.dig("answer").presence || fallback_answer_for(@note.body)

    Note.create!(
      agency:       @agency,
      patient:      @patient,
      parent_note:  thread_anchor,        # thread the answer under the question
      author_role:  "admissions",
      body:         reply_text,
      urgency:      "normal",
      source:       "system",
      family_offer: offer_reply?(reply_text)
    )

    # If the brain decided the family accepted an offer to contact a
    # named clinician, execute it: drop a clinician_only urgent note
    # that @-mentions the right person, which fires the existing
    # OutboundPing pipeline (Telegram / SMS / email).
    notify = result&.dig("notify")
    # A nurse-timing question always flags the patient's nurse so they reach out
    # with an update — unless the brain already emitted a notify, or we already
    # flagged them about timing recently (don't ping on every "any update?").
    if notify.nil? && timing_question?(@note.body) && !recently_flagged_nurse_about_timing?
      notify = { "role" => "visit_rn",
                 "reason" => "Family is asking when the next nurse visit is, please reach out with the timing." }
      record_timing_inquiry!
    end
    execute_notify(notify) if notify

    AgentEvent.create!(
      agency:      @agency,
      agent_id:    "hosalivio_brain",
      action:      "answer_family_question",
      subject:     @patient,
      happened_at: Time.current,
      change_set: {
        family_user_id: @note.author_user_id,
        source:         result&.dig("source"),
        chars_in:       @note.body.to_s.length,
        chars_out:      reply_text.length,
        answered:       result.present?,
        notified_role:  notify&.dig("role")
      }
    )

    @note.mark_read!
  ensure
    Current.reset
  end

  # Last 8 messages on this patient's thread, oldest first, with bodies
  # truncated so the context window stays small. Filters out clinician-
  # only audit chatter (rationale notes, guardrail blocks) since the
  # family side of the conversation is what matters for "did HosAlivio
  # offer something the user is now confirming?".
  def recent_thread_context
    notes = @patient.notes
                    .where(clinician_only: [ nil, false ])
                    .where.not(id: @note.id)
                    .order(created_at: :desc).limit(8)
                    .reverse
    notes.map do |n|
      role = n.ai_authored? ? "hosalivio" : (n.author_role == "family" ? "family" : "clinician")
      { role: role, body: n.body.to_s[0, 600], sent_at: n.created_at.iso8601 }
    end
  end

  # Translates the brain's structured notify directive into actual
  # plumbing: find the right human (role-scoped, branch-preferred),
  # post a clinician_only chart note, and create a Notification for
  # their inbox/outbound channels. If no human matches the role, fall
  # back to a generic on-call notice for the role's queue.
  def execute_notify(notify)
    role   = notify["role"].to_s
    reason = notify["reason"].to_s.strip
    return if role.empty?

    target = resolve_clinician_for_role(role)
    return if target.nil?

    first = target.full_name.to_s.split(/\s+/, 2).first || "team"
    # Strip the clinician's own name from the reason so the rendered
    # body doesn't read "@Pascal contact Pascal Benoit". The brain's
    # prompt already asks for situation-not-clinician language; this
    # is the safety net.
    reason = scrub_clinician_name(reason, target)
    body   = "@#{first} #{reason.presence || "family confirmed they want you to reach out"}"
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

    # This path wakes a real human, so it belongs in the agent audit trail
    # alongside emit_handoff. It previously wrote only a Note + Notification and
    # no AgentEvent, which meant an escalation could be invisible to the Mission
    # Stage feed and to anything querying AgentEvent — "we alerted the nurse" was
    # not provable from one place. Same action verb and change_set shape as
    # ClinicianDispatcher's relay, so AgentEvent.escalations covers both paths.
    AgentEvent.create!(
      agency:           @agency,
      agent_id:         "triage",
      agent_session_id: Current.agent_session_id,
      action:           "notify_clinician",
      subject:          @patient,
      change_set:       { target_role: role, target_user_id: target.id,
                          target_name: target.full_name, reason: reason.presence,
                          urgency: @note.urgency.to_s },
      happened_at:      Time.current
    )
  rescue => e
    Rails.logger.warn("[HosalivioTriager#execute_notify] #{e.class}: #{e.message}")
  end

  # Drops the target clinician's name from the reason text so the
  # @-mention doesn't read with the name twice. Handles "Pascal
  # Benoit", "Pascal", "Mr. Benoit", "with Pascal", "to Pascal" etc.
  # If stripping leaves the reason empty, fall back to a generic
  # phrase so the @-mention still reads as a complete sentence.
  CONNECTOR_RE = /\b(?:with|to|by|from|for|contact|reach|reach\s+out\s+to|in|of|notify|page|page\s+in|loop\s+in|alert)\b/i.freeze

  def scrub_clinician_name(reason, target)
    return reason if reason.blank? || target.nil?
    full  = target.full_name.to_s.strip
    first = full.split(/\s+/, 2).first.to_s
    last  = full.split(/\s+/, 2).last.to_s
    cleaned = reason.dup
    # Pass 1: try to remove the connector + name together so we don't
    # leave dangling prepositions ("contact with" / "loop in").
    [ full, "#{first} #{last}", first, last ].uniq.reject(&:blank?).each do |name|
      cleaned = cleaned.gsub(/#{CONNECTOR_RE.source}\s+#{Regexp.escape(name)}\b/i, "")
    end
    # Pass 2: anything still standing alone, drop just the name.
    [ full, "#{first} #{last}", first, last ].uniq.reject(&:blank?).each do |name|
      cleaned = cleaned.gsub(/\b#{Regexp.escape(name)}\b/i, "")
    end
    # Pass 3: collapse whitespace, prune dangling tail connectors,
    # and tidy commas / sentence-final punctuation.
    cleaned = cleaned.gsub(/\s+/, " ").strip
    cleaned = cleaned.sub(/^,\s*/, "").gsub(/\s+,/, ",").gsub(/,\s*,/, ",")
    cleaned = cleaned.sub(/#{CONNECTOR_RE.source}\s*[,.]?\s*$/i, "").strip
    cleaned = cleaned.sub(/^[,.\s]+/, "").sub(/[,\s]+$/, "")
    cleaned
  end

  # Patient-assigned clinician first (assigned_rn / assigned_md / etc),
  # then the agency's on-call user for that role at the patient's
  # branch, then any active user at the agency in that role.
  def resolve_clinician_for_role(role)
    by_assignment = case role
    when "rn"            then @patient.assigned_rn
    when "visit_rn"      then @patient.assigned_visit_rn || @patient.assigned_rn
    when "md"            then @patient.assigned_md
    when "sw", "social_worker" then @patient.assigned_sw
    when "chaplain"      then @patient.assigned_chaplain
    end
    return by_assignment if by_assignment

    base = User.where(agency_id: @agency.id, active: true, family_access: false)
               .joins(user_roles: :role)
               .where(roles: { name: role == "social_worker" ? "social_worker" : role })
    base = base.where(branch_id: @patient.branch_id) if @patient.branch_id
    base.order(on_call: :desc).first
  end

  # Was the most recent non-family note authored by a real human user
  # (not an AI / system note) within the conversation window? If so,
  # there's a live human-to-family thread in progress and the AI should
  # not interject. Crisis messages bypass this — those always trigger.
  def human_clinician_recently_active?
    @patient.notes
            .where("created_at > ?", HUMAN_CONVERSATION_WINDOW.ago)
            .where.not(id: @note.id)
            .where.not(author_role: "family")
            .where.not(author_user_id: nil)
            .where(clinician_only: false)
            .exists?
  end

  def internal_triage_body(d, roles)
    intent_label = INTENT_LABELS[d[:intent]] || d[:intent].to_s.humanize
    role_targets = roles.map { |r| name_for_role(r) }
    urgency_word = d[:urgency].to_s.capitalize

    parts = [ "#{intent_label} · #{urgency_word}",
             "Notified: #{role_targets.join(', ')}" ]
    parts << "" << d[:reasoning].to_s.strip if d[:reasoning].present?
    parts.join("\n")
  end

  # Resolve a role to a human label. Patient-assigned slot wins (assigned_rn,
  # assigned_md, etc.); otherwise pick the in-branch user with that role.
  # Falls back to the bare role label if nobody fits.
  #
  # Names are emitted with an "@" prefix so the audit-row helper can
  # parse them into clickable mention buttons. Skips honorifics like
  # "Dr." / "Mr." / "Ms." when picking the first name token, so we get
  # @Esther instead of @Dr.
  def name_for_role(role)
    role_label = ROLE_LABELS[role] || role.humanize
    user = patient_assigned_user(role) || branch_user_for_role(role)
    return role_label unless user
    "@#{first_name_for_mention(user)} (#{role_label})"
  end

  HONORIFICS = %w[dr. mr. mrs. ms. mx. rev. fr. sr.].freeze

  def first_name_for_mention(user)
    tokens = user.full_name.to_s.split.reject { |t| HONORIFICS.include?(t.downcase) }
    tokens.first.presence || user.full_name.to_s.split.first
  end

  def patient_assigned_user(role)
    case role
    when "rn"            then @patient.assigned_rn
    when "md"            then @patient.assigned_md
    when "social_worker" then @patient.respond_to?(:assigned_sw) ? @patient.assigned_sw : nil
    when "chaplain"      then @patient.respond_to?(:assigned_chaplain) ? @patient.assigned_chaplain : nil
    end
  end

  def branch_user_for_role(role)
    base = User.joins(user_roles: :role)
               .where(agency: @agency, active: true)
               .where(roles: { name: role })
    base = base.where(branch_id: @patient.branch_id) if @patient.branch_id
    base.first || User.joins(user_roles: :role)
                      .where(agency: @agency, active: true)
                      .where(roles: { name: role })
                      .first
  end

  def emit_handoff(role, intent, urgency)
    AgentEvent.create!(
      agency:           @agency,
      agent_id:         "triage",
      agent_session_id: Current.agent_session_id,
      action:           "handoff",
      subject:          @patient,
      change_set:       { target_role: role, intent: intent, urgency: urgency },
      happened_at:      Time.current
    )
  end

  # "claude:claude-sonnet-4-6" -> "claude", "fallback:regex" -> "fallback"
  def brain_suffix(source)
    source.to_s.split(":").first.presence || "unknown"
  end
end
