# Compiles a compact, factual snapshot of a patient that HosAlivio can
# read when answering a clinician's question in chat. Stays small (the
# whole hash typically serializes to <2 KB) so we don't blow context
# budget on Claude calls.
#
# Role-scoped: the requester's role gates which facts get compiled,
# matching what each discipline legitimately needs. Aides never see
# medication doses or diagnostic detail; chaplains never see vitals.
# This keeps PHI exposure to the LLM minimal-by-design rather than
# relying on the model to filter via system prompt.

class PatientContextBuilder
  FULL_CLINICAL = %w[rn md don admissions admin ceo].freeze
  AIDE_ONLY     = %w[aide].freeze
  PSYCHOSOCIAL  = %w[sw social_worker chaplain].freeze
  FAMILY        = %w[family].freeze

  def self.call(patient:, role:)
    new(patient, role).call
  end

  def initialize(patient, role)
    @patient = patient
    @role    = role.to_s
    @scope   = scope_for(@role)
  end

  def call
    {
      patient:        patient_block,
      schedule:       schedule_block,
      family:         family_block,
      consents:       consents_block,
      visits:         visits_block,
      medications:    %i[psychosocial family].include?(@scope) ? medications_block_lay : medications_block,
      vitals:         @scope == :psychosocial ? nil : vitals_block,
      pre_admit_eval: @scope == :family ? eval_block_lay : eval_block,
      dme:            dme_block,
      pharmacy:       @scope == :family ? nil : pharmacy_block,
      care_team:      care_team_block,
      agency_staff:   agency_staff_block
    }.compact
  end

  private

  def scope_for(role)
    return :full_clinical if FULL_CLINICAL.include?(role)
    return :aide          if AIDE_ONLY.include?(role)
    return :psychosocial  if PSYCHOSOCIAL.include?(role)
    return :family        if FAMILY.include?(role)
    :full_clinical # default to broadest; downstream guardrails still apply
  end

  # Lay-friendly meds list for family + psychosocial roles. Returns
  # generic descriptions ("long-acting opioid for pain") instead of
  # specific drug names + doses + frequencies. Family seeing exact
  # doses in chat creates a self-administration risk we want to avoid.
  def medications_block_lay
    orders = @patient.medication_orders.where(status: :active).order(created_at: :desc)
    return nil if orders.none?
    orders.map do |o|
      indication = o.prn ? o.prn_indication.to_s.presence : nil
      indication ||= case o.drug_name.to_s.downcase
      when /morphine|oxycodone|fentanyl|methadone|hydromorphone/ then "pain"
      when /lorazepam|midazolam|haloperidol/                     then "anxiety / restlessness"
      when /ondansetron|haloperidol/                              then "nausea"
      when /atropine|glycopyrrolate/                              then "secretions"
      when /senna|bisacodyl/                                     then "constipation"
      else                                                            "comfort"
      end
      class_label = case o.drug_name.to_s.downcase
      when /morphine.+er|methadone|fentanyl/        then "long-acting comfort medication"
      when /morphine|oxycodone|hydromorphone/        then "comfort medication"
      when /lorazepam|midazolam/                     then "anxiety medication"
      when /haloperidol/                              then "calming medication"
      when /ondansetron/                              then "anti-nausea medication"
      when /senna|bisacodyl|polyethylene/            then "bowel regimen"
      else "comfort medication"
      end
      {
        category:   class_label,
        for:        indication,
        as_needed:  o.prn
      }.compact
    end
  end

  # Lay-friendly version of the eval block for family. Strips
  # ICD-10 codes, narrative summaries, and PPS justification.
  def eval_block_lay
    e = PreAdmitEval.where(patient_id: @patient.id).order(created_at: :desc).first
    return nil if e.nil?
    pdx = e.diagnosis_section["primary_terminal_diagnosis"].is_a?(Hash) ? e.diagnosis_section["primary_terminal_diagnosis"] : {}
    {
      status:        e.status,
      evaluated_at:  e.evaluated_at&.iso8601,
      certified_at:  e.certified_at&.iso8601,
      primary_dx:    pdx["description"] # description only, no ICD-10
    }.compact
  end

  def patient_block
    {
      name:                @patient.full_name,
      mrn:                 @patient.mrn,
      dob:                 @patient.dob&.iso8601,
      preferred_language:  @patient.preferred_language,
      code_status:         @patient.code_status,
      hospice_election_at: @patient.hospice_election_date&.iso8601,
      cert_period_end:     @patient.cert_period_end&.iso8601,
      days_in_hospice:     @patient.hospice_election_date ? (Date.current - @patient.hospice_election_date).to_i : nil,
      days_to_recert:      @patient.cert_period_end ? (@patient.cert_period_end - Date.current).to_i : nil,
      branch:              @patient.branch&.name
    }.compact
  end

  def schedule_block
    last_completed = @patient.visits.where.not(ended_at: nil).order(ended_at: :desc).first
    in_progress    = @patient.visits.where.not(started_at: nil).where(ended_at: nil).order(started_at: :desc).first
    {
      last_completed_visit: visit_summary(last_completed),
      in_progress_visit:    visit_summary(in_progress)
    }.compact
  end

  def visits_block
    # Most-recent-activity first, stable regardless of status (a scheduled
    # visit with no started_at still sorts by its scheduled date instead of
    # falling to the bottom). Keeps the summary in clean chronological order.
    visits = @patient.visits
                     .order(Arel.sql("COALESCE(started_at, scheduled_at, created_at) DESC"))
                     .limit(5)
    visits.map { |v| visit_summary(v) }.compact
  end

  def visit_summary(v)
    return nil if v.nil?
    # Explicit, unambiguous status derived from the timestamps so HosAlivio
    # never has to infer "completed" from the presence of a clinician name or
    # a started_at. completed = has ended_at; in_progress = started, not ended;
    # scheduled = neither.
    status = if v.ended_at.present?      then "completed"
    elsif v.started_at.present? then "in progress"
    else                             "scheduled"
    end
    {
      id:           v.id,
      type:         v.visit_type,
      discipline:   v.discipline,
      status:       status,
      clinician:    v.user&.full_name,
      scheduled_at: v.scheduled_at&.iso8601,
      started_at:   v.started_at&.iso8601,
      ended_at:     v.ended_at&.iso8601,
      narrative:    @scope == :aide ? nil : truncate_text(v.narrative, 600),
      vitals:       (@scope == :psychosocial ? nil : v.vitals.presence)
    }.compact
  end

  def medications_block
    orders = @patient.medication_orders.where(status: :active).order(created_at: :desc)
    return nil if orders.none?
    orders.map do |o|
      last_admin = o.medication_logs.order(administered_at: :desc).first&.administered_at
      {
        drug:           o.drug_name,
        dose:           o.dose,
        route:          o.route,
        frequency:      o.frequency,
        prn:            o.prn,
        prn_indication: o.prn ? o.prn_indication : nil,
        last_given_at:  last_admin&.iso8601
      }.compact
    end
  end

  def vitals_block
    recent = @patient.visits.where.not(ended_at: nil)
                              .where("vitals != '{}'")
                              .order(ended_at: :desc).limit(3)
    return nil if recent.empty?
    recent.map { |v| { at: v.ended_at&.iso8601, vitals: v.vitals } }
  end

  def family_block
    fam = User.where(patient_id: @patient.id, family_access: true).order(:full_name)
    return nil if fam.empty?
    fam.map do |f|
      {
        name:     f.full_name,
        relation: f.relationship.presence,
        active:   f.active
      }.compact
    end
  end

  def consents_block
    return nil unless @patient.respond_to?(:dnr) || @patient.respond_to?(:polst_on_file)
    {
      code_status:    @patient.code_status,
      polst_on_file:  @patient.polst_on_file
    }.compact
  end

  def eval_block
    e = PreAdmitEval.where(patient_id: @patient.id).order(created_at: :desc).first
    return nil if e.nil?
    pdx = e.diagnosis_section["primary_terminal_diagnosis"].is_a?(Hash) ? e.diagnosis_section["primary_terminal_diagnosis"] : {}
    {
      id:             e.id,
      status:         e.status,
      evaluated_at:   e.evaluated_at&.iso8601,
      finalized_at:   e.finalized_at&.iso8601,
      certified_at:   e.certified_at&.iso8601,
      certified_by:   e.certified_by&.full_name,
      primary_dx:     pdx["description"],
      primary_icd10:  pdx["icd10"],
      lcd_criteria:   Array(e.diagnosis_section["lcd_criteria_met"]),
      pps:            e.pps_score,
      blockers:       e.certification_blockers,
      missing_documents: e.missing_required_documents,
      narrative_summary: (@scope == :aide ? nil : truncate_text(e.general_comments["narrative_summary"], 400))
    }.compact
  end

  def dme_block
    items = @patient.dme_orders.where.not(status: %i[picked_up returned]).order(requested_at: :desc)
    return nil if items.none?
    items.map do |d|
      {
        equipment:    d.equipment_type,
        status:       d.status,
        requested_at: d.requested_at&.iso8601,
        quantity:     d.quantity
      }.compact
    end
  end

  def pharmacy_block
    pending = @patient.pharmacy_deliveries.where.not(status: %i[delivered refused]).order(created_at: :desc)
    return nil if pending.none?
    pending.map do |p|
      {
        kind:       p.kind,
        status:     p.status,
        drug:       p.medication_order&.drug_name,
        created_at: p.created_at.iso8601
      }.compact
    end
  end

  # Patient-specific assigned care team. So HosAlivio can answer
  # "who is her RN?" without scanning the whole agency roster.
  def care_team_block
    {
      assigned_rn:       user_summary(@patient.assigned_rn),
      assigned_md:       user_summary(@patient.assigned_md),
      social_worker:     user_summary(@patient.assigned_sw),
      chaplain:          user_summary(@patient.assigned_chaplain)
    }.compact
  end

  # Agency-wide staff roster grouped by role, scoped to the patient's
  # branch when one is set. Lets HosAlivio answer "who handles
  # Medicaid verification?", "who's the billing contact?", or "who at
  # admissions can take this?" with real names. Filtered to active
  # users only.
  def agency_staff_block
    return nil unless @patient.agency_id
    base = User.unscoped
                 .where(agency_id: @patient.agency_id, active: true, family_access: false)
    base = base.where(branch_id: @patient.branch_id) if @patient.branch_id
    users = base.includes(user_roles: :role).to_a
    return nil if users.empty?
    {
      admissions: users.select { |u| u.role_names.include?("admissions") }.map { |u| user_summary(u) }.compact,
      insurance:  users.select { |u| u.role_names.include?("insurance")  }.map { |u| user_summary(u) }.compact,
      billing:    users.select { |u| u.role_names.include?("billing")    }.map { |u| user_summary(u) }.compact,
      don:        users.select { |u| u.role_names.include?("don")        }.map { |u| user_summary(u) }.compact,
      admin:      users.select { |u| u.role_names.include?("admin")      }.map { |u| user_summary(u) }.compact
    }.transform_values { |arr| arr.empty? ? nil : arr }.compact
  end

  def user_summary(user)
    return nil unless user
    {
      name:    user.full_name,
      role:    (user.role_names & %w[rn md don sw social_worker chaplain aide admissions admin insurance billing]).first,
      on_call: user.respond_to?(:on_call) ? user.on_call : nil
    }.compact
  end

  def truncate_text(text, max)
    s = text.to_s
    return nil if s.strip.empty?
    s.length > max ? "#{s[0, max]}…" : s
  end
end
