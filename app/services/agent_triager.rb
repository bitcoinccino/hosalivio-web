# Generalized agent action-taker.
#
# Receives a decision hash from AgentBrain and executes the corresponding
# DB write (or handoff) inside the agency's tenant scope. One class handles
# every role; role differences live in the brain's decision, not here.
#
# Usage:
#   AgentTriager.new(role: "rn", agency: agency, event: triggering_event, depth: 2).apply(decision)
#
# Always returns the object it created (or nil for no_action).

class AgentTriager
  def initialize(role:, agency:, event: nil, depth: 1)
    @role   = role.to_s
    @agency = agency
    @event  = event
    @depth  = depth.to_i
  end

  def apply(decision)
    action = decision[:action]
    params = (decision[:params] || {}).with_indifferent_access

    # Stamp Current so AgentAuditable attributes every downstream write
    # to the acting agent, not to whoever was acting before.
    prev_agency  = Current.agency
    prev_agent   = Current.agent_id
    prev_session = Current.agent_session_id

    Current.agency           = @agency
    Current.agent_id         = @role
    Current.agent_session_id = "#{@role}-#{SecureRandom.hex(4)}"

    result = ActsAsTenant.with_tenant(@agency) do
      case action
      when "write_note"           then write_note(params)
      when "write_visit"          then write_visit(params)
      when "write_med_order"      then write_med_order(params)
      when "write_pharm_delivery" then write_pharm_delivery(params)
      when "write_dme_order"      then write_dme_order(params)
      when "write_pre_admit_eval" then write_pre_admit_eval(params)
      when "certify_pre_admit_eval" then certify_pre_admit_eval(params)
      when "file_noe"             then file_noe(params)
      when "handoff_to"           then emit_handoff(params, decision)
      when "broadcast_reply"      then broadcast_reply(params)
      when "no_action"            then nil
      else
        Rails.logger.warn("[AgentTriager:#{@role}] unknown action #{action.inspect}")
        nil
      end
    end

    log_audit_note(decision) if decision[:reasoning].present? && action != "no_action"
    result
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[AgentTriager:#{@role}] invalid record: #{e.record.errors.full_messages.to_sentence}")
    nil
  ensure
    Current.agency           = prev_agency
    Current.agent_id         = prev_agent
    Current.agent_session_id = prev_session
  end

  # ──────────────────────────────────────────────────────────────────

  private

  # write_note has two distinct meanings depending on the role:
  #
  #   admissions  → family-facing chat reply (the canonical AI voice)
  #   everyone else → CLINICAL CHART ENTRY (clinician_only documentation)
  #
  # The chart entry is what makes the MD / RN / SW / chaplain agents
  # actually do work — they document assessments, plans, and rationale
  # in the medical record. Family doesn't see chart entries. broadcast_reply
  # is the separate action for "speak to the family" and is gated to
  # admissions only.
  def write_note(p)
    patient_id = p[:patient_id] || fallback_patient_id
    return nil if patient_id.blank?

    effective_role = p[:author_role].presence || @role
    is_chart_only  = effective_role.to_s != "admissions"

    Note.create!(
      agency:         @agency,
      patient_id:     patient_id,
      author_role:    effective_role,
      body:           p[:body].to_s.strip,
      urgency:        normalize_urgency(p[:urgency]),
      source:         p[:source].presence || "system",
      clinician_only: is_chart_only
    )
  end

  # broadcast_reply is the "speak to the family" action. Only admissions
  # may use it; any other role's broadcast_reply is dropped so we never
  # get two AI bubbles (admissions + 'Pascal') in the family thread.
  def broadcast_reply(p)
    unless @role == "admissions"
      Rails.logger.info("[AgentTriager:#{@role}] refused broadcast_reply (admissions is the single family-facing voice)")
      return nil
    end
    write_note(p.merge(author_role: "admissions"))
  end

  def write_visit(p)
    patient_id = p[:patient_id] || fallback_patient_id
    return nil if patient_id.blank?

    Visit.create!(
      agency:          @agency,
      patient_id:      patient_id,
      user_id:         p[:user_id] || user_for_role&.id,
      discipline:      (p[:discipline].presence || @role).to_s,
      visit_type:      p[:visit_type].presence || "routine",
      scheduled_at:    p[:scheduled_at],
      started_at:      p[:started_at],
      ended_at:        p[:ended_at],
      narrative:       p[:narrative],
      vitals:          (p[:vitals].is_a?(Hash) ? p[:vitals] : {}),
      pain_score:      p[:pain_score],
      billable:        p[:billable].nil? ? true : ActiveModel::Type::Boolean.new.cast(p[:billable]),
      visit_code:      p[:visit_code],
      agent_authored:  true
    )
  end

  def write_med_order(p)
    patient_id = p[:patient_id] || fallback_patient_id
    return nil if patient_id.blank?

    # MDs are the only role that should create med orders. Guard at the triager
    # layer too, not just in the prompt, so a confused prompt can't bypass it.
    unless @role == "md" || @role == "admin"
      Rails.logger.warn("[AgentTriager:#{@role}] refused write_med_order (only MD can prescribe)")
      return nil
    end

    order = MedicationOrder.create!(
      agency:           @agency,
      patient_id:       patient_id,
      prescribed_by_id: p[:prescribed_by_id] || user_for_role("md")&.id,
      drug_name:        p[:drug_name].to_s.strip,
      dose:             p[:dose].to_s.strip,
      route:            p[:route].presence || "po",
      frequency:        p[:frequency].to_s.strip,
      prn:              ActiveModel::Type::Boolean.new.cast(p[:prn]),
      prn_indication:   p[:prn_indication],
      start_date:       p[:start_date] || Date.current,
      end_date:         p[:end_date],
      status:           :active
    )
    label = "#{order.drug_name} #{order.dose}".strip
    emit_action_banner(patient_id, "med_ordered", label, urgency: p[:urgency])
    order
  end

  def write_pharm_delivery(p)
    patient_id = p[:patient_id] || fallback_patient_id
    return nil if patient_id.blank?

    delivery = PharmacyDelivery.create!(
      agency:              @agency,
      patient_id:          patient_id,
      medication_order_id: p[:medication_order_id],
      kind:                p[:kind].presence || "refill",
      status:              p[:status].presence || "requested",
      delivered_at:        p[:delivered_at]
    )
    emit_action_banner(patient_id, "pharmacy_dispatched", delivery.kind.to_s.tr("_", " ").titleize, urgency: p[:urgency])
    delivery
  end

  def write_dme_order(p)
    patient_id = p[:patient_id] || fallback_patient_id
    return nil if patient_id.blank?

    dme = DmeOrder.create!(
      agency:         @agency,
      patient_id:     patient_id,
      equipment_type: p[:equipment_type].presence || "other",
      quantity:       (p[:quantity] || 1).to_i,
      vendor:         p[:vendor],
      status:         :requested,
      requested_at:   Time.current,
      notes:          p[:notes]
    )
    label = dme.equipment_type.to_s.tr("_", " ").titleize
    label += " ×#{dme.quantity}" if dme.quantity > 1
    emit_action_banner(patient_id, "dme_requested", label, urgency: p[:urgency])
    dme
  end

  def emit_handoff(p, decision)
    target = p[:target_role].to_s
    return nil if target.blank? || target == @role

    AgentEvent.create!(
      agency:           @agency,
      agent_id:         @role,
      agent_session_id: Current.agent_session_id,
      action:           "handoff",
      subject:          @event&.subject || fallback_patient,
      change_set: {
        target_role: target,
        intent:      p[:intent],
        urgency:     normalize_urgency(p[:urgency]),
        reasoning:   decision[:reasoning],
        # Depth rides along so the next agent knows how deep it is in the chain.
        depth:       @depth + 1
      },
      happened_at: Time.current
    )
  end

  # Emit a structured "action landed" note. The chat UI detects the
  # [ACTION:...] prefix and renders this as a green success banner so
  # Pascal can see at-a-glance what the agent did, instead of reading
  # through the rationale prose.
  def emit_action_banner(patient_id, action_type, label, urgency: nil)
    return if patient_id.blank?
    Note.create!(
      agency:         @agency,
      patient_id:     patient_id,
      author_role:    @role,
      body:           "[ACTION:#{action_type}] #{label}",
      urgency:        normalize_urgency(urgency),
      source:         :system,
      clinician_only: true
    )
  rescue ActiveRecord::RecordInvalid
    nil
  end

  # Compact internal trace note so a human auditor can follow every brain
  # decision later. Only when the agent did something non-trivial.
  def log_audit_note(decision)
    patient_id = decision.dig(:params, :patient_id) || fallback_patient_id
    return if patient_id.blank?
    role_label = HosalivioTriager::ROLE_LABELS[@role] || @role.humanize
    Note.create!(
      agency:         @agency,
      patient_id:     patient_id,
      author_role:    @role,
      body:           "#{role_label} rationale\n\n#{decision[:reasoning].to_s.strip}",
      urgency:        :normal,
      source:         :system,
      clinician_only: true
    )
  rescue ActiveRecord::RecordInvalid
    nil
  end

  # ── helpers ────────────────────────────────────────────────────────

  def normalize_urgency(raw)
    val = raw.to_s.downcase
    %w[crisis urgent normal].include?(val) ? val : "normal"
  end

  def fallback_patient
    return @event.subject if @event&.subject.is_a?(Patient)
    return @event.subject.patient if @event&.subject.respond_to?(:patient)
    nil
  end

  def fallback_patient_id
    fallback_patient&.id
  end

  # ── Pre-admit eval workflow ─────────────────────────────────────
  #
  # Pascal → write_pre_admit_eval (status: final) → auto-handoff MD
  # Esther → certify_pre_admit_eval                 → auto-handoff Insurance
  # Kendra → file_noe                                → eval.status = noe_filed
  #
  # Each transition stamps an AgentEvent so the Mission Stage shows the
  # full chain of custody from bedside assessment to Medicare filing.

  def write_pre_admit_eval(p)
    patient_id = p[:patient_id] || fallback_patient_id
    return nil if patient_id.blank?

    raw = p[:raw_json] || p[:pre_admit_eval] || p
    raw = raw.to_h if raw.respond_to?(:to_h)
    raw = { "pre_admit_eval" => raw } unless raw.is_a?(Hash) && raw.key?("pre_admit_eval")

    validation = PreAdmitValidator.call(raw)
    unless validation.ok?
      Rails.logger.warn("[AgentTriager:#{@role}] pre_admit_eval validation failed: #{validation.errors.join('; ')}")
      return nil
    end

    evaluator = user_for_role("rn")
    eval_record = PreAdmitEval.create!(
      agency:           @agency,
      patient_id:       patient_id,
      visit_id:         p[:visit_id],
      evaluator:        evaluator,
      evaluator_name:   evaluator&.full_name || p[:evaluator_name],
      evaluator_license: evaluator&.license_number || p[:evaluator_license],
      evaluator_role:   @role,
      raw_json:         validation.cleaned_json,
      status:           (p[:draft] ? :draft : :final),
      evaluated_at:     Time.current,
      finalized_at:     (p[:draft] ? nil : Time.current)
    )

    if eval_record.status_final?
      # Auto-handoff to MD for certification.
      AgentEvent.create!(
        agency:           @agency,
        agent_id:         @role,
        agent_session_id: Current.agent_session_id,
        action:           "handoff",
        subject:          eval_record,
        change_set: {
          target_role:   "md",
          intent:        "pre_admit_certification",
          urgency:       "normal",
          depth:         @depth + 1,
          eval_id:       eval_record.id,
          patient_name:  eval_record.patient.full_name,
          primary_icd10: eval_record.primary_icd10,
          warnings:      validation.warnings
        },
        happened_at: Time.current
      )
    end

    eval_record
  end

  def certify_pre_admit_eval(p)
    eval_id = p[:eval_id] || @event&.subject_id
    return nil unless eval_id

    certifier = user_for_role("md")
    eval_record = PreAdmitEval.find(eval_id)
    return nil unless eval_record.status_final?

    # Consent + LCD gate: Esther cannot sign until Pascal has captured the
    # informed consent, election, AOB, and a supported diagnosis. Handing
    # back to Pascal instead of forcing a certification avoids the "fake
    # consent" audit finding that fails every CMS recertification survey.
    unless eval_record.can_certify?
      Rails.logger.warn("[AgentTriager:#{@role}] refusing to certify eval=#{eval_id}; blockers: #{eval_record.certification_blockers.join('; ')}")
      AgentEvent.create!(
        agency:           @agency,
        agent_id:         @role,
        agent_session_id: Current.agent_session_id,
        action:           "handoff",
        subject:          eval_record,
        change_set: {
          target_role:   "rn",
          intent:        "pre_admit_completion_needed",
          urgency:       "urgent",
          depth:         @depth + 1,
          eval_id:       eval_record.id,
          patient_name:  eval_record.patient.full_name,
          blockers:      eval_record.certification_blockers
        },
        happened_at: Time.current
      )
      return nil
    end

    eval_record.update!(
      status:       :certified,
      certified_at: Time.current,
      certified_by: certifier
    )

    # Auto-handoff to Insurance for NOE filing.
    AgentEvent.create!(
      agency:           @agency,
      agent_id:         @role,
      agent_session_id: Current.agent_session_id,
      action:           "handoff",
      subject:          eval_record,
      change_set: {
        target_role:   "insurance",
        intent:        "file_noe",
        urgency:       "urgent",   # 5-day Medicare clock is ticking
        depth:         @depth + 1,
        eval_id:       eval_record.id,
        patient_name:  eval_record.patient.full_name,
        noe_deadline:  eval_record.noe_deadline_at&.iso8601
      },
      happened_at: Time.current
    )

    eval_record
  end

  def file_noe(p)
    eval_id = p[:eval_id] || @event&.subject_id
    return nil unless eval_id

    eval_record = PreAdmitEval.find(eval_id)
    return nil unless eval_record.status_certified?

    eval_record.update!(
      status:       :noe_filed,
      noe_filed_at: Time.current
    )

    eval_record
  end

  # Find a clinician user holding the given role at this agency. Used when
  # the LLM doesn't name a specific user_id but we still need to stamp one
  # on a Visit or MedicationOrder.
  #
  # Layered preference, in order:
  #   1. Same branch as the patient (so Orlando stays in Orlando)
  #   2. User whose service_zips cover the patient's ZIP (intra-branch territory)
  #   3. For urgent/crisis at night or weekend, on-call users first
  #   4. Users below their max_caseload
  #   5. Whoever's left in the agency (fallback)
  def user_for_role(target_role = @role)
    patient = fallback_patient
    base = User.joins(user_roles: :role)
               .where(agency: @agency, active: true)
               .where(roles: { name: target_role })

    candidates = base.to_a
    return nil if candidates.empty?

    # 1. Narrow to patient's branch if known.
    if patient&.branch_id
      in_branch = candidates.select { |u| u.branch_id == patient.branch_id }
      candidates = in_branch if in_branch.any?
    end

    # 2. Narrow further by ZIP if patient has one and some candidates declare coverage.
    if patient&.zip.present?
      zip_covered = candidates.select { |u| u.covers_zip?(patient.zip) }
      candidates = zip_covered if zip_covered.any?
    end

    # 3. After-hours + urgent → prefer on-call.
    if urgent? && after_hours?(patient)
      on_call = candidates.select(&:on_call)
      candidates = on_call if on_call.any?
    end

    # 4. Prefer users under capacity over at-capacity.
    under_cap = candidates.reject(&:at_capacity?)
    candidates = under_cap if under_cap.any?

    # 5. Within the final pool, pick the least-loaded.
    candidates.min_by(&:current_caseload)
  end

  def urgent?
    u = @event&.change_set.is_a?(Hash) ? @event.change_set["urgency"].to_s : ""
    %w[crisis urgent].include?(u)
  end

  # After hours = outside 08:00-18:00 local at the patient's branch (or Eastern
  # as a fallback). Weekends always count.
  def after_hours?(patient)
    tz = patient&.branch&.timezone.presence || "America/New_York"
    now = Time.current.in_time_zone(tz)
    now.saturday? || now.sunday? || now.hour < 8 || now.hour >= 18
  end
end
