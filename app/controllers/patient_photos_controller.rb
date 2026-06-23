class PatientPhotosController < ApplicationController
  before_action :authenticate_user!
  before_action :set_patient
  before_action :authorize_editor!

  PRIVILEGED_ROLES = %w[admin don admissions].freeze

  def create
    file = params.dig(:patient, :photo) || params[:photo]
    if file.blank?
      return redirect_to patient_path(@patient), alert: "Choose an image to upload."
    end

    ActsAsTenant.with_tenant(@patient.agency) do
      @patient.photo.attach(file)
      if @patient.save
        redirect_to patient_path(@patient), notice: "Photo updated for #{@patient.first_name}."
      else
        @patient.photo.purge if @patient.photo.attached?
        redirect_to patient_path(@patient), alert: @patient.errors.full_messages.to_sentence
      end
    end
  end

  def destroy
    ActsAsTenant.with_tenant(@patient.agency) do
      @patient.photo.purge if @patient.photo.attached?
    end
    redirect_to patient_path(@patient), notice: "Photo removed for #{@patient.first_name}."
  end

  private

  def set_patient
    ActsAsTenant.with_tenant(current_user.agency) do
      @patient = Patient.find(params[:patient_id])
    end
  end

  # Same rule as inviting family: the patient's assigned RN/MD, an admin, DON,
  # or admissions coordinator may change the chart photo.
  def authorize_editor!
    return if (current_user.role_names & PRIVILEGED_ROLES).any?
    return if [@patient.assigned_rn_id, @patient.assigned_md_id].include?(current_user.id)
    redirect_to patient_path(@patient), alert: "Only the assigned clinician, admin, DON, or admissions can change the photo."
  end
end
