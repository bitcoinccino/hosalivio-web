class PatientChatsController < ApplicationController
  before_action :authenticate_user!
  before_action :load_patient
  before_action :authorize_patient_access

  def show
    ActsAsTenant.with_tenant(@agency) do
      base_notes = @patient.notes
      base_notes = base_notes.family_visible if current_user.family_access?
      @notes     = base_notes.order(created_at: :desc).limit(50).to_a.reverse
      @idg_roster = build_idg_roster(@patient)

      # Right-rail clinical context
      @active_orders      = @patient.medication_orders.where(status: :active).includes(:medication_logs).order(created_at: :desc).to_a
      @recent_visits      = @patient.visits.order(started_at: :desc).limit(10).to_a
      @latest_vitals_visit = @recent_visits.find { |v| v.vitals.present? && v.vitals.any? }
      @active_dme         = @patient.dme_orders.where.not(status: [:picked_up, :returned]).order(requested_at: :desc).to_a
      @pending_deliveries = @patient.pharmacy_deliveries.where.not(status: [:delivered, :refused]).order(created_at: :desc).to_a
      @unresolved_crisis  = @patient.notes.where(author_role: "family", urgency: :crisis, read_at: nil).count
      @days_in_hospice    = @patient.hospice_election_date ? (Date.current - @patient.hospice_election_date).to_i : nil
      @days_to_recert     = @patient.cert_period_end ? (@patient.cert_period_end - Date.current).to_i : nil

      # Next-due schedule per active order + a "headline" med for the chat header
      @order_schedules    = @active_orders.index_with { |o| MedicationSchedule.for(o) }
      @headline_order     = pick_headline_order(@active_orders, @order_schedules)

      # Timeline window: last 12h of logs for all active orders (for SVG ribbon)
      @timeline_window_hours = 12
      window_start           = @timeline_window_hours.hours.ago
      @timeline_logs         = MedicationLog
                                 .where(medication_order_id: @active_orders.map(&:id))
                                 .where("administered_at > ?", window_start)
                                 .order(:administered_at)
                                 .to_a

      # Vitals trend data — collect up to 8 most-recent visits with vitals
      @vitals_visits  = @recent_visits.select { |v| v.vitals.present? && v.vitals.any? && v.started_at }.first(8).reverse
      @vitals_series  = build_vitals_series(@vitals_visits)

      # Family users linked to this patient (for the sidebar Family section)
      @family_users = User.where(patient_id: @patient.id, family_access: true).order(active: :desc, full_name: :asc)
      @pre_admit_eval = PreAdmitEval.where(patient: @patient).order(created_at: :desc).first
      @can_invite_family =
        !current_user.family_access? &&
        ((current_user.role_names & PatientFamiliesController::PRIVILEGED_ROLES).any? ||
         [@patient.assigned_rn_id, @patient.assigned_md_id].include?(current_user.id))
    end
  end

  def load_patient
    @patient = Patient.unscoped.find(params[:id])
    @agency  = @patient.agency
  end

  # Family: only their assigned patient. Clinicians: any patient in their agency.
  def authorize_patient_access
    if current_user.family_access?
      head(:forbidden) unless current_user.patient_id == @patient.id
    else
      head(:forbidden) unless current_user.agency_id == @agency.id
    end
  end

  private

  private

  # Returns one row per IDG discipline for the left sidebar.
  def build_idg_roster(patient)
    roster = [
      { role: "admissions",    name: "Lucia (Front Door)",       user: nil },
      { role: "rn",            name: nil,                         user: patient.assigned_rn },
      { role: "md",            name: nil,                         user: patient.assigned_md },
      { role: "social_worker", name: nil,                         user: patient.assigned_sw },
      { role: "chaplain",      name: nil,                         user: patient.assigned_chaplain }
    ]
    roster.map do |row|
      row[:name] ||= row[:user]&.full_name || humanize_role(row[:role])
      row[:present] = row[:user].present? || row[:role] == "admissions"
      row
    end
  end

  def humanize_role(role)
    {
      "rn" => "RN Case Manager (unassigned)",
      "md" => "Hospice Physician (unassigned)",
      "social_worker" => "Social Worker (unassigned)",
      "chaplain" => "Chaplain (unassigned)"
    }.fetch(role, role.humanize)
  end

  # Prefer an overdue PRN, then soonest-due. Fallback to first order.
  def pick_headline_order(orders, schedules)
    return nil if orders.empty?
    ranked = orders.sort_by { |o|
      s = schedules[o]
      [s[:status] == :overdue ? 0 : (s[:status] == :available ? 1 : 2),
       s[:minutes] || Float::INFINITY]
    }
    ranked.first
  end

  # Extract numeric series for each vitals metric across visits.
  # vitals JSON looks like: { "temp" => 98.2, "bp" => "128/76", "pulse" => 88, "resp" => 18, "o2" => 95 }
  def build_vitals_series(visits)
    return {} if visits.empty?
    temps   = visits.map { |v| v.vitals["temp"]&.to_f }
    pulses  = visits.map { |v| v.vitals["pulse"]&.to_i }
    resps   = visits.map { |v| v.vitals["resp"]&.to_i }
    o2s     = visits.map { |v| v.vitals["o2"]&.to_i }
    systolic = visits.map { |v| v.vitals["bp"].to_s.split("/").first&.to_i }
    {
      temp:   temps,
      pulse:  pulses,
      resp:   resps,
      o2:     o2s,
      bp_sys: systolic,
      times:  visits.map { |v| v.started_at },
      raw_bp: visits.map { |v| v.vitals["bp"].to_s }
    }
  end
end
