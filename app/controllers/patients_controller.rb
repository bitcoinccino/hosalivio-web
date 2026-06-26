class PatientsController < ApplicationController
  before_action :authenticate_user!
  before_action :redirect_family_users
  before_action :authorize_registrar!

  # Registering a patient is an agency-admin job (same roles that schedule
  # visits). Clinicians work from patients admissions has registered.
  REGISTRAR_ROLES = %w[admin don admissions].freeze

  def new
    ActsAsTenant.with_tenant(current_user.agency) do
      @patient = Patient.new(status: :referred, code_status: :full_code, benefit_period: :bp1_90)
    end
  end

  def create
    ActsAsTenant.with_tenant(current_user.agency) do
      @patient = Patient.new(patient_params)
      @patient.agency = current_user.agency
      if @patient.save
        redirect_to patient_path(@patient), status: :see_other,
          notice: "#{@patient.full_name} registered (MRN #{@patient.mrn}). Schedule their admission visit next."
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
end
