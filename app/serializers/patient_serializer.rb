class PatientSerializer
  include JSONAPI::Serializer

  attributes :mrn, :status, :code_status, :gender, :preferred_language,
             :hospice_election_date, :benefit_period,
             :cert_period_start, :cert_period_end,
             :advance_directive_on_file, :polst_on_file,
             :allergies, :assigned_rn_id, :assigned_md_id,
             :assigned_sw_id, :assigned_chaplain_id,
             :created_at, :updated_at

  # Decrypted PHI — agents calling the API legitimately need this.
  # For patient/family-facing UI, build a separate masked serializer.
  attributes :first_name, :last_name, :dob, :phone, :email,
             :address_line1, :address_line2, :city, :state, :zip,
             :primary_diagnosis, :secondary_diagnoses,
             :caregiver_name, :caregiver_phone

  attribute(:age_years) { |p| p.age_years }
  attribute(:full_name) { |p| p.full_name }
end
