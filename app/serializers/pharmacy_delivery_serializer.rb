class PharmacyDeliverySerializer
  include JSONAPI::Serializer
  attributes :patient_id, :medication_order_id, :confirmed_by_id,
             :kind, :status, :delivered_at,
             :created_at, :updated_at
end
