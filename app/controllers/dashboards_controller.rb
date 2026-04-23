class DashboardsController < ApplicationController
  before_action :authenticate_user!
  before_action :redirect_family_users

  MANAGER_ROLES = %w[admin don admissions ceo].freeze
  CLINICAL_ROLES = %w[rn md social_worker chaplain aide dme pharmacy insurance billing].freeze

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
    @open_inquiries = Inquiry.where(status: [:new_lead, :claimed]).order(created_at: :desc).limit(10)

    compliance_scope    = User.where(agency: @agency, active: true)
    @licenses_expired   = compliance_scope.where("license_expires_on < ?", Date.current).count
    @licenses_expiring  = compliance_scope.where(license_expires_on: Date.current..(Date.current + 60.days)).count

    @pending_certifications = PreAdmitEval.where(agency: @agency, status: :final).order(:evaluated_at).includes(:patient)
    @pending_noe            = PreAdmitEval.where(agency: @agency, status: :certified).order(:noe_deadline_at).includes(:patient)
    @noe_overdue            = @pending_noe.select(&:noe_overdue?)
    @noe_due_today          = @pending_noe.select { |e| e.noe_deadline_at && e.noe_deadline_at.to_date <= Date.current + 1.day && !e.noe_overdue? }

    @unresolved_note_ids = Note.where(author_role: "family", urgency: :crisis, read_at: nil).pluck(:id)

    patient_ids = @recent_events.map { |ev|
      ev.subject_type == "Patient" ? ev.subject_id : ev.subject.try(:patient_id)
    }.compact.uniq
    patients_by_id = Patient.where(id: patient_ids).index_by(&:id)
    @stories = EventNarrator.stories_from(@recent_events, patient_lookup: patients_by_id)
  end

  # Data for the clinician "My Day" home.
  def load_my_day
    me = current_user
    today_start = Date.current.in_time_zone.beginning_of_day
    today_end   = Date.current.in_time_zone.end_of_day

    # Today's visits on this clinician's calendar
    @todays_visits = Visit.where(user_id: me.id)
                          .where("COALESCE(scheduled_at, started_at) BETWEEN ? AND ?", today_start, today_end)
                          .order(Arel.sql("COALESCE(scheduled_at, started_at) ASC"))
                          .includes(:patient)

    # Patients on my caseload — anyone where I'm any of the four assigned_* roles
    @caseload = Patient.where(agency: @agency).where(
      "assigned_rn_id = :id OR assigned_md_id = :id OR assigned_sw_id = :id OR assigned_chaplain_id = :id",
      id: me.id
    ).order(:created_at)

    caseload_ids = @caseload.pluck(:id)

    # Open family crises on my caseload (unread, urgency=crisis, author=family)
    @open_crises = Note.where(patient_id: caseload_ids, author_role: "family",
                              urgency: :crisis, read_at: nil)
                       .order(created_at: :desc).limit(5).includes(:patient)

    # Handoffs targeting my role that haven't been acted on yet
    @pending_handoffs = AgentEvent.where(agency: @agency, action: "handoff")
                                   .where("happened_at > ?", 7.days.ago)
                                   .order(happened_at: :desc)
                                   .select { |ev| ev.change_set.is_a?(Hash) && me.role_names.include?(ev.change_set["target_role"]) }
                                   .first(8)

    # Overdue comfort meds on my caseload
    overdue = []
    active_orders = MedicationOrder.where(patient_id: caseload_ids, status: :active).includes(:patient)
    active_orders.find_each do |o|
      sched = MedicationSchedule.for(o)
      overdue << { order: o, schedule: sched } if sched[:status] == :overdue
    end
    @overdue_meds = overdue.sort_by { |r| r[:schedule][:minutes].to_i }.first(5)

    @my_license_status = me.license_status
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
