class PatientsController < ApplicationController
  before_action :authenticate_user!
  before_action :redirect_family_users
  before_action :authorize_registrar!

  # Registering a patient is an agency-admin job (same roles that schedule
  # visits). Clinicians work from patients admissions has registered.
  REGISTRAR_ROLES = %w[admin admissions].freeze

  # The patient roster — search, filter, and register. Replaces the old
  # Coordination page's "new registrations" half.
  def index
    @agency = current_user.agency
    ActsAsTenant.with_tenant(current_user.agency) do
      @q      = params[:q].to_s.strip
      @status = params[:status].to_s.strip
      @branch = params[:branch_id].to_s.strip

      scope = Patient.where(agency: current_user.agency)
      scope = scope.where(status: @status)        if Patient.statuses.key?(@status)
      scope = scope.where(branch_id: @branch)     if @branch.present?
      rows  = scope.order(created_at: :desc).limit(500).to_a

      # Name is deterministically encrypted (no SQL LIKE), so filter the free
      # text against name + MRN in Ruby. The roster is agency-sized, so fine.
      if @q.present?
        needle = @q.downcase
        rows   = rows.select { |p| p.full_name.downcase.include?(needle) || p.mrn.to_s.downcase.include?(needle) }
      end
      @patients = rows.first(200)

      # Latest visit per patient → the care-stage badge (Admission / Follow-up /
      # Routine-Continuous), in one query instead of N+1.
      ids = @patients.map(&:id)
      @latest_visit_by_patient =
        Visit.where(patient_id: ids)
             .order(Arel.sql("COALESCE(started_at, scheduled_at, created_at) DESC"))
             .group_by(&:patient_id)
             .transform_values(&:first)

      @branches       = Branch.where(agency: current_user.agency, active: true).order(:name)
      @status_counts  = Patient.where(agency: current_user.agency).group(:status).count
      @total_patients = Patient.where(agency: current_user.agency).count
    end
  end

  def new
    ActsAsTenant.with_tenant(current_user.agency) do
      @patient = Patient.new(status: :referred, code_status: :full_code, benefit_period: :bp1_90)
    end
  end

  def create
    ActsAsTenant.with_tenant(current_user.agency) do
      @patient = Patient.new(patient_params)
      @patient.agency = current_user.agency
      @patient.intake = intake_params
      if @patient.save
        redirect_to patient_path(@patient), status: :see_other,
          notice: "#{@patient.full_name} registered (MRN #{@patient.mrn}). Schedule their admission visit next."
      else
        flash.now[:alert] = @patient.errors.full_messages.to_sentence
        render :new, status: :unprocessable_entity
      end
    end
  end

  def edit
    ActsAsTenant.with_tenant(current_user.agency) { @patient = Patient.find(params[:id]) }
    render :new   # the registration view doubles as the edit form (model-driven)
  end

  def update
    ActsAsTenant.with_tenant(current_user.agency) do
      @patient = Patient.find(params[:id])
      @patient.assign_attributes(patient_params)
      @patient.intake = @patient.intake.merge(intake_params)
      if @patient.save
        redirect_to patient_path(@patient), status: :see_other,
          notice: "#{@patient.full_name}'s intake updated."
      else
        flash.now[:alert] = @patient.errors.full_messages.to_sentence
        render :new, status: :unprocessable_entity
      end
    end
  end

  # PATCH /patients/:id/reassign_rn — change the patient's case-manager RN.
  # Gated to REGISTRAR_ROLES by the authorize_registrar! before_action
  # (mirrors PatientPolicy#update?). Only touches assigned_rn_id; a blank
  # value unassigns. Validates the target is an active RN in this agency.
  def reassign_rn
    ActsAsTenant.with_tenant(current_user.agency) do
      patient = Patient.find(params[:id])
      rn_id   = params[:assigned_rn_id].presence
      rn      = rn_id && agency_rns.find_by(id: rn_id)

      if rn_id && rn.nil?
        return redirect_to patient_path(patient), status: :see_other,
          alert: "That nurse isn't an active RN in your agency."
      end

      patient.update!(assigned_rn_id: rn&.id)
      redirect_to patient_path(patient), status: :see_other,
        notice: rn ? "#{patient.full_name} reassigned to #{rn.full_name}." \
                   : "#{patient.full_name}'s RN was unassigned."
    end
  end

  # PATCH /patients/:id/reassign_member — assign/unassign a care-team nurse
  # slot. `field` selects the slot; blank `user_id` unassigns. Validates the
  # target holds the right role in this agency. Same REGISTRAR_ROLES gate.
  ASSIGNABLE_NURSE_SLOTS = {
    "rn"       => { column: :assigned_rn_id,       pool: :rn,  label: "Admission Nurse" },
    "visit_rn" => { column: :assigned_visit_rn_id, pool: :rn,  label: "Primary Nurse" },
    "lpn"      => { column: :assigned_lpn_id,      pool: :lpn, label: "Support Nurse" }
  }.freeze

  def reassign_member
    ActsAsTenant.with_tenant(current_user.agency) do
      patient = Patient.find(params[:id])
      slot    = ASSIGNABLE_NURSE_SLOTS[params[:field].to_s]
      return redirect_to(patient_path(patient), status: :see_other, alert: "Unknown assignment.") unless slot

      pool    = slot[:pool] == :lpn ? agency_lpns : agency_rns
      user_id = params[:user_id].presence
      user    = user_id && pool.find_by(id: user_id)
      if user_id && user.nil?
        return redirect_to patient_path(patient), status: :see_other,
          alert: "That person isn't an active #{slot[:label]} in your agency."
      end

      patient.update!(slot[:column] => user&.id)
      redirect_to patient_path(patient), status: :see_other,
        notice: user ? "#{patient.full_name}'s #{slot[:label]} set to #{user.full_name}." \
                      : "#{patient.full_name}'s #{slot[:label]} was unassigned."
    end
  end

  private

  # Active users with the RN role in the current agency — the pool of
  # valid reassignment targets.
  def agency_rns
    User.joins(user_roles: :role)
        .where(agency: current_user.agency, active: true)
        .where(roles: { name: "rn" })
        .distinct
        .order(:full_name)
  end

  def agency_lpns
    User.joins(user_roles: :role)
        .where(agency: current_user.agency, active: true)
        .where(roles: { name: "lpn" })
        .distinct
        .order(:full_name)
  end

  def redirect_family_users
    return unless current_user&.family_access?
    redirect_to(current_user.patient_id ? patient_path(current_user.patient_id) : welcome_path)
  end

  def authorize_registrar!
    return if (current_user.role_names & REGISTRAR_ROLES).any?
    redirect_back fallback_location: dashboard_path,
                  alert: "Only an admin, DON, or admissions coordinator can register patients."
  end

  def patient_params
    params.require(:patient).permit(
      :first_name, :last_name, :preferred_name, :pronouns, :dob, :gender,
      :preferred_language, :interpreter_needed, :religion,
      :veteran_status, :veteran_branch,
      :address_line1, :address_line2, :city, :state, :zip, :phone, :email, :branch_id,
      :primary_diagnosis, :secondary_diagnoses,
      :caregiver_name, :caregiver_phone, :caregiver_relationship,
      :status, :code_status, :benefit_period
    )
  end

  # The loose intake blob fields (see Patient::INTAKE_KEYS). Nested under
  # patient[intake][...]; the model allowlists + stringifies on assignment.
  def intake_params
    raw = params.dig(:patient, :intake)
    raw.blank? ? {} : raw.permit(*Patient::INTAKE_KEYS).to_h
  end
end
