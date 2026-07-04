class DashboardsController < ApplicationController
  before_action :authenticate_user!
  before_action :redirect_family_users

  MANAGER_ROLES = %w[admin don admissions].freeze
  CLINICAL_ROLES = %w[rn md social_worker chaplain aide dme pharmacy insurance billing].freeze

  MENTION_ROLE_LABELS = {
    "rn" => "RN", "lpn" => "LPN", "md" => "MD", "don" => "DON",
    "social_worker" => "SW", "sw" => "SW", "chaplain" => "Chaplain",
    "aide" => "Aide", "admissions" => "Admissions", "insurance" => "Insurance",
    "billing" => "Billing", "admin" => "Admin", "pharmacy" => "Pharmacy", "dme" => "DME"
  }.freeze
  MENTION_ROLES = MENTION_ROLE_LABELS.keys.freeze

  def show
    @agency = current_user.agency || Agency.first
    if @agency.nil?
      @patients = []
      @recent_events = []
      return
    end

    ActsAsTenant.with_tenant(@agency) do
      roles = current_user.role_names
      if (roles & MANAGER_ROLES).any?
        load_mission_stage
        render :show
      elsif (roles & CLINICAL_ROLES).any?
        load_my_day
        render :my_day
      else
        # Unknown/system user — fall through to the manager view.
        load_mission_stage
        render :show
      end
    end
  end

  private

  def load_mission_stage
    @patients       = Patient.order(created_at: :desc).limit(25)
    @recent_events  = AgentEvent.order(happened_at: :desc).limit(80).to_a
    @open_inquiries = Inquiry.where(status: [ :new_lead, :claimed ]).order(created_at: :desc).limit(10)

    compliance_scope    = User.where(agency: @agency, active: true)
    @licenses_expired   = compliance_scope.where("license_expires_on < ?", Date.current).count
    @licenses_expiring  = compliance_scope.where(license_expires_on: Date.current..(Date.current + 60.days)).count

    @pending_certifications = PreAdmitEval.where(agency: @agency, status: :final).order(:evaluated_at).includes(:patient)
    @pending_noe            = PreAdmitEval.where(agency: @agency, status: :certified).order(:noe_deadline_at).includes(:patient)
    @noe_overdue            = @pending_noe.select(&:noe_overdue?)
    @noe_due_today          = @pending_noe.select { |e| e.noe_deadline_at && e.noe_deadline_at.to_date <= Date.current + 1.day && !e.noe_overdue? }

    # Quick-stat counts for the dashboard header.
    @active_patient_count = Patient.where(agency: @agency, status: :active).count
    @open_blockers        = (@pending_certifications.to_a + @pending_noe.to_a).count { |e| e.certification_blockers.present? }

    # Team channels for the composer's "+" menu (readable to this user).
    Channel.ensure_defaults_for(@agency)
    @channels = Channel.order(:position, :slug).select { |c| c.readable_by?(current_user) }

    # @-mention pool for team-chat mode: active staff in this agency.
    @mentionables = build_mentionables

    @unresolved_note_ids = Note.where(author_role: "family", urgency: :crisis, read_at: nil).pluck(:id)

    # Recent + upcoming visits across the agency (yesterday → next 7 days),
    # so the oversight screen shows who's being seen and when, not just the
    # eval/NOE backlog. Ordered by the visit's anchor time (scheduled, else
    # started). Status is derived per-row in the view.
    visit_window_start = (Date.current - 1.day).in_time_zone.beginning_of_day
    visit_window_end   = (Date.current + 7.days).in_time_zone.end_of_day
    @mission_visits = Visit.where(agency: @agency)
                           .where("COALESCE(scheduled_at, started_at) BETWEEN ? AND ?", visit_window_start, visit_window_end)
                           .order(Arel.sql("COALESCE(scheduled_at, started_at) ASC"))
                           .includes(:patient, :user)
                           .limit(25)

    patient_ids = @recent_events.map { |ev|
      ev.subject_type == "Patient" ? ev.subject_id : ev.subject.try(:patient_id)
    }.compact.uniq
    patients_by_id = Patient.where(id: patient_ids).index_by(&:id)
    @stories = EventNarrator.stories_from(@recent_events, patient_lookup: patients_by_id)
  end

  # Data for the clinician "My Day" home — loads shared panels + the
  # role-specific priority data the partial will render above them.
  def load_my_day
    me = current_user
    @primary_role = (me.role_names & CLINICAL_ROLES).first || "rn"
    today_start = Date.current.in_time_zone.beginning_of_day
    today_end   = Date.current.in_time_zone.end_of_day

    # Auto-discard truly-empty in-progress visits owned by this
    # clinician older than 5 minutes. Catches the case where Pascal
    # tapped Start a visit, then closed the tab / hit browser back /
    # got distracted, leaving a phantom 'In progress' row on his
    # dashboard. Visits with any narrative or audio are kept so we
    # don't throw away real work.
    Visit.unscoped.where(user_id: me.id)
                   .where.not(started_at: nil)
                   .where(ended_at: nil)
                   .where("started_at < ?", 5.minutes.ago)
                   .find_each do |v|
      next if v.narrative.to_s.strip.present?
      next if v.audio_note.attached?
      v.destroy
    end

    @todays_visits = Visit.where(user_id: me.id)
                          .where("COALESCE(scheduled_at, started_at) BETWEEN ? AND ?", today_start, today_end)
                          .order(Arel.sql("COALESCE(scheduled_at, started_at) ASC"))
                          .includes(:patient)

    @caseload = Patient.where(agency: @agency).where(
      "assigned_rn_id = :id OR assigned_md_id = :id OR assigned_sw_id = :id OR assigned_chaplain_id = :id",
      id: me.id
    ).order(:created_at)
    caseload_ids = @caseload.pluck(:id)

    @open_crises = Note.where(patient_id: caseload_ids, author_role: "family",
                              urgency: :crisis, read_at: nil)
                       .order(created_at: :desc).limit(5).includes(:patient)

    @pending_handoffs = AgentEvent.where(agency: @agency, action: "handoff")
                                   .where("happened_at > ?", 7.days.ago)
                                   .order(happened_at: :desc)
                                   .select { |ev| ev.change_set.is_a?(Hash) && me.role_names.include?(ev.change_set["target_role"]) }
                                   .first(8)

    overdue = []
    active_orders = MedicationOrder.where(patient_id: caseload_ids, status: :active).includes(:patient)
    active_orders.find_each do |o|
      sched = MedicationSchedule.for(o)
      overdue << { order: o, schedule: sched } if sched[:status] == :overdue
    end
    @overdue_meds = overdue.sort_by { |r| r[:schedule][:minutes].to_i }.first(5)

    @my_license_status = me.license_status

    # Role-specific priority data
    case @primary_role
    when "md"
      # Only this MD's queue: evals for patients they're the assigned MD on,
      # plus any patient with no MD assigned yet (so an unassigned eval still
      # reaches someone instead of being invisible to everyone).
      @pending_certs = PreAdmitEval.where(agency: @agency, status: :final)
                                    .joins(:patient)
                                    .where("patients.assigned_md_id = :me OR patients.assigned_md_id IS NULL", me: me.id)
                                    .order(:evaluated_at).includes(:patient)
      @upcoming_recerts = Patient.where(agency: @agency)
                                  .where.not(cert_period_end: nil)
                                  .where(cert_period_end: Date.current..(Date.current + 14.days))
                                  .where("assigned_md_id = :me OR assigned_md_id IS NULL", me: me.id)
                                  .order(:cert_period_end)
      # Evals this MD bounced back to the RN that haven't been re-routed yet,
      # so they can track what they're waiting on.
      @awaiting_revision = EvalRevisionRequest.open
                                              .where(requester_id: me.id)
                                              .recent_first
                                              .includes(pre_admit_eval: :patient)
      # Patient-id sets so the caseload can show cert-status pills for the MD
      # without a per-patient query (data already loaded above).
      @md_cert_pending_pids = @pending_certs.map(&:patient_id)
      @md_revision_pids     = @awaiting_revision.filter_map { |r| r.pre_admit_eval&.patient_id }
    when "social_worker"
      @psychosocial_due = Patient.where(agency: @agency, status: :active, assigned_sw_id: me.id)
                                  .where("hospice_election_date >= ?", 5.days.ago).order(:hospice_election_date)
      @bereavement_queue = Patient.where(agency: @agency, status: :deceased, assigned_sw_id: me.id)
                                   .order(updated_at: :desc).limit(10)
    when "chaplain"
      @spiritual_due = Patient.where(agency: @agency, status: :active, assigned_chaplain_id: me.id)
                               .where("hospice_election_date >= ?", 5.days.ago).order(:hospice_election_date)
      @bereavement_queue = Patient.where(agency: @agency, status: :deceased, assigned_chaplain_id: me.id)
                                   .order(updated_at: :desc).limit(10)
    when "aide"
      @today_aide_plans = @todays_visits
    when "dme"
      @dme_pending = DmeOrder.where(agency: @agency).where.not(status: [ :picked_up, :returned ])
                             .order(requested_at: :desc).limit(12).includes(:patient)
      @dme_pickups = Patient.where(agency: @agency, status: [ :deceased, :discharged ])
                             .order(updated_at: :desc).limit(6)
    when "pharmacy"
      @pharmacy_pending = PharmacyDelivery.where(agency: @agency)
                                           .where.not(status: [ :delivered, :refused ])
                                           .order(created_at: :desc).limit(12).includes(:patient)
    when "insurance"
      @noe_due = PreAdmitEval.where(agency: @agency, status: :certified)
                              .order(:noe_deadline_at).includes(:patient)
      @bp_rollovers = Patient.where(agency: @agency)
                              .where.not(cert_period_end: nil)
                              .where(cert_period_end: Date.current..(Date.current + 14.days))
                              .order(:cert_period_end)
    when "billing"
      # Placeholder buckets until the claims model lands
      @claims_pending = []
      @denials_pending = []
    end
  end

  # The @-mention pool for team-chat mode: active, non-family staff in this
  # agency (excluding the current user). Each entry: { handle, name, role }.
  # Mirrors PatientChatsController#build_mentionables.
  def build_mentionables
    return [] if @agency.nil?

    User.joins(user_roles: :role)
        .where(agency: @agency, active: true, family_access: false)
        .where(roles: { name: MENTION_ROLES })
        .where.not(id: current_user.id)
        .distinct.order(:full_name).limit(40).to_a.filter_map do |u|
      first = u.full_name.to_s.split.first
      next if first.blank?
      role = (u.role_names & MENTION_ROLES).first
      { handle: first, name: u.full_name, role: MENTION_ROLE_LABELS[role] || role.to_s.titleize }
    end
  end

  # Family users have no business on the mission stage — send them to their patient.
  def redirect_family_users
    return unless current_user&.family_access?
    if current_user.patient_id.present?
      redirect_to patient_path(current_user.patient_id)
    else
      sign_out current_user
      redirect_to welcome_path, alert: "Your account is not linked to a patient yet."
    end
  end
end
