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

  def triage!
    # 0 — SUPPRESS if a human clinician is actively in this thread
    if human_clinician_recently_active? && !@note.urgency_crisis?
      Rails.logger.info("[HosalivioTriager] suppressing AI — human clinician active in thread for patient=#{@patient.id}")
      @note.mark_read!
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

    # 4 — FAMILY-FACING REPLY (broadcasts to the chat UI via Note callback)
    Note.create!(
      agency:      @agency,
      patient:     @patient,
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

    parts = ["#{intent_label} · #{urgency_word}",
             "Notified: #{role_targets.join(', ')}"]
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
