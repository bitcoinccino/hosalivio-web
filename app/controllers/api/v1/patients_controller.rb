module Api
  module V1
    class PatientsController < BaseController
      def index
        patients = policy_scope(Patient).order(created_at: :desc).limit(100)
        render json: PatientSerializer.new(patients).serializable_hash
      end

      def show
        patient = Patient.find(params[:id])
        authorize patient
        render json: PatientSerializer.new(patient).serializable_hash
      end

      def create
        authorize Patient
        patient = Patient.new(patient_params)
        patient.agency = Current.agency
        patient.save!
        render json: PatientSerializer.new(patient).serializable_hash, status: :created
      end

      def update
        patient = Patient.find(params[:id])
        authorize patient
        patient.update!(patient_params)
        render json: PatientSerializer.new(patient).serializable_hash
      end

      private

      def patient_params
        params.require(:patient).permit(
          :first_name, :last_name, :dob, :gender, :preferred_language,
          :address_line1, :address_line2, :city, :state, :zip, :phone, :email,
          :primary_diagnosis, :secondary_diagnoses,
          :hospice_election_date, :benefit_period, :cert_period_start, :cert_period_end,
          :status, :code_status, :advance_directive_on_file, :polst_on_file,
          :caregiver_name, :caregiver_phone,
          :assigned_rn_id, :assigned_md_id, :assigned_sw_id, :assigned_chaplain_id,
          allergies: []
        )
      end
    end
  end
end
