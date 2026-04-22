class DmeOrderSerializer
  include JSONAPI::Serializer
  attributes :patient_id, :equipment_type, :quantity, :vendor, :status,
             :requested_at, :delivered_at, :picked_up_at, :notes,
             :created_at, :updated_at
end
