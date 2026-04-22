class MedicationOrderSerializer
  include JSONAPI::Serializer
  attributes :patient_id, :prescribed_by_id,
             :drug_name, :dose, :route, :frequency,
             :prn, :prn_indication,
             :start_date, :end_date, :status,
             :created_at, :updated_at
end
