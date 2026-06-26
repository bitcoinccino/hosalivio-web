# Basic document upload for a patient's chart — store + download signed forms,
# photos of paperwork, etc. Clinicians only. No AI reading (MVP).
class PatientDocumentsController < ApplicationController
  before_action :authenticate_user!
  before_action :load_patient
  before_action :authorize_clinician!

  def index
    ActsAsTenant.with_tenant(@agency) do
      @documents = @patient.patient_documents.with_attached_file.newest_first.to_a
      @document  = PatientDocument.new
    end
  end

  def create
    ActsAsTenant.with_tenant(@agency) do
      file  = params.dig(:patient_document, :file)
      title = params.dig(:patient_document, :title).to_s.strip
      title = file&.original_filename.to_s if title.blank?

      @document = @patient.patient_documents.build(
        agency: @agency, uploaded_by: current_user, title: title,
        kind: params.dig(:patient_document, :kind).presence
      )
      @document.file.attach(file) if file

      if @document.save
        redirect_to patient_documents_path(@patient), status: :see_other, notice: "Document uploaded."
      else
        @documents = @patient.patient_documents.with_attached_file.newest_first.to_a
        flash.now[:alert] = @document.errors.full_messages.to_sentence
        render :index, status: :unprocessable_entity
      end
    end
  end

  def destroy
    ActsAsTenant.with_tenant(@agency) do
      @patient.patient_documents.find(params[:id]).destroy
    end
    redirect_to patient_documents_path(@patient), status: :see_other, notice: "Document removed."
  end

  private

  def load_patient
    @patient = Patient.unscoped.find(params[:patient_id])
    @agency  = @patient.agency
  end

  # Clinicians in the patient's agency only; family never sees documents.
  def authorize_clinician!
    head(:forbidden) if current_user.family_access? || current_user.agency_id != @agency.id
  end
end
