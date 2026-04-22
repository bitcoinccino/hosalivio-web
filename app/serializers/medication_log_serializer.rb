class MedicationLogSerializer
  include JSONAPI::Serializer
  attributes :medication_order_id, :administered_by_id,
             :administered_at, :dose_given, :effective, :side_effects, :source,
             :created_at, :updated_at
end
