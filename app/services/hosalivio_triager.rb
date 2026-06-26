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
    "pain_crisis"        => %w[rn md],
    "dyspnea"            => %w[rn md],
    "decline"            => %w[rn],
    "caregiver_distress" => %w[social_worker chaplain],
    "transitioning"      => %w[rn chaplain],
    "med_refill"         => %w[pharmacy rn],
    "spiritual"          => %w[chaplain social_worker],
    "logistics"          => %w[dme rn],
    "status_question"    => %w[rn],
    "other"              => %w[rn]
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
    "spiritual"          => "Spiritual support",
    "logistics"          => "Logistics request",
    "status_question"    => "Status check",
    "other"              => "General message"
  }.freeze

  ROLE_LABELS = {
    "rn"            => "RN",
    "md"            => "MD",
    "social_worker" => "Social Worker",
    "chaplain"     => "Chaplain",
    "pharmacy"      => "Pharmacy",
    "dme"           => "DME",
    "insurance"     => "Insurance",
    "aide"          => "Aide",
    "don"           => "DON",
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

  def triage!
    # 0 — SUPPRESS if a human clinician is actively in this thread
    if human_clinician_recently_active? && !@note.urgency_crisis?
      Rails.logger.info("[HosalivioTriager] suppressing AI — human clinician active in thread for patient=#{@patient.id}")
      @note.mark_read!
      return
    end

    # 0.5 — Context-aware short-circuit. Either (a) a question worth
    # answering directly, or (b) a short reply ("yes", "thanks") that
    # only makes sense in the context of HosAlivio's prior turn.
    # Both routes go through answer_family! which feeds the thread
    # context to the brain. Crisis messages still use the normal
    # triage below because they need handoffs even when phrased
    # conversationally.
    if !@note.urgency_crisis? && (looks_like_question?(@note.body) || context_reply?(@note.body))
      answer_family!
      return
    end

    # 1 — ASK THE BRAIN (never raises; returns fallback on failure)
    decision = HosalivioBrain.call(note: @note)
    roles    = ESCALATION_ROLES.fetch(decision[:intent], ESCALATION_ROLES["other"])

    # Stamp Current so AgentAuditable attributes every write to HosAlivio's session.
    Current.agency           = @agency
    Current.agent_id         = "admissions"
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

    # 4 — FAMILY-FACING REPLY (broadcasts to the chat UI via Note callback).
    #     Threaded under the family's message so the question + HosAlivio's
    #     answer read as one conversation. parent is family-visible, so the
    #     reply inherits family visibility.
    Note.create!(
      agency:      @agency,
      patient:     @patient,
      parent_note: thread_anchor,
      author_role: "admissions",
      body:        decision[:reply],
      urgency:     "normal",     # reply itself is calm; urgency captured internally
      source:      "system"
    )

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

  # Family Q&A path. Calls HosalivioBrain.answer_clinician_question with
  # role: "family" (which gates the patient context to lay-friendly,
  # no specific drug names/doses) and posts the answer as a normal,
  # family-visible HosAlivio reply. Audit-logged for compliance.
  def answer_family!
    Current.agency           = @agency
    Current.agent_id         = "admissions"
    Current.agent_session_id = "hosalivio-family-qa-#{SecureRandom.hex(4)}"

    result = HosalivioBrain.answer_clinician_question(
      question:       @note.body.to_s,
      patient:        @patient,
      role:           "family",
      thread_context: recent_thread_context
    )
    reply_text = result&.dig("answer").presence || "I'm not able to answer that just now. I've nudged the care team so someone can get back to you."

    Note.create!(
      agency:      @agency,
      patient:     @patient,
      parent_note: thread_anchor,        # thread the answer under the question
      author_role: "admissions",
      body:        reply_text,
      urgency:     "normal",
      source:      "system"
    )

    # If the brain decided the family accepted an offer to contact a
    # named clinician, execute it: drop a clinician_only urgent note
    # that @-mentions the right person, which fires the existing
    # OutboundPing pipeline (Telegram / SMS / email).
    if (notify = result&.dig("notify"))
      execute_notify(notify)
    end

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
      agent_id:         "admissions",
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
