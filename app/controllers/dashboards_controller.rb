class DashboardsController < ApplicationController
  before_action :authenticate_user!
  before_action :redirect_family_users

  def show
    # Each clinician sees their own agency's data. Fall back to first agency
    # only for the edge case of a system user with no agency assigned.
    @agency = current_user.agency || Agency.first
    if @agency.nil?
      @patients = []
      @recent_events = []
      return
    end

    ActsAsTenant.with_tenant(@agency) do
      @patients      = Patient.order(created_at: :desc).limit(25)
      @recent_events = AgentEvent.order(happened_at: :desc).limit(80).to_a
      @open_inquiries = Inquiry.where(status: [:new_lead, :claimed]).order(created_at: :desc).limit(10)

      # Compliance compile for the CEO/DON rollup tile. Managers only; no
      # privacy concern surfacing a count to anyone in the tenant.
      compliance_scope = User.where(agency: @agency, active: true)
      @licenses_expired  = compliance_scope.where("license_expires_on < ?", Date.current).count
      @licenses_expiring = compliance_scope.where(license_expires_on: Date.current..(Date.current + 60.days)).count

      # Pre-admit pipeline rollup (managers only)
      @pending_certifications = PreAdmitEval.where(agency: @agency, status: :final).order(:evaluated_at).includes(:patient)
      @pending_noe            = PreAdmitEval.where(agency: @agency, status: :certified).order(:noe_deadline_at).includes(:patient)
      @noe_overdue            = @pending_noe.select(&:noe_overdue?)
      @noe_due_today          = @pending_noe.select { |e| e.noe_deadline_at && e.noe_deadline_at.to_date <= Date.current + 1.day && !e.noe_overdue? }

      # IDs of currently "open" crisis notes (family crisis that isn't read/replied yet)
      @unresolved_note_ids = Note.where(author_role: "family", urgency: :crisis, read_at: nil).pluck(:id)

      # Pre-resolve each event's patient so the narrator can link names.
      patient_ids = @recent_events.map { |ev|
        ev.subject_type == "Patient" ? ev.subject_id : ev.subject.try(:patient_id)
      }.compact.uniq
      patients_by_id = Patient.where(id: patient_ids).index_by(&:id)

      @stories = EventNarrator.stories_from(@recent_events, patient_lookup: patients_by_id)
    end
  end

  private

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
