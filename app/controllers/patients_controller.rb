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

  private

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
