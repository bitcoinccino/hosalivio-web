class VisitSerializer
  include JSONAPI::Serializer

  attributes :patient_id, :user_id, :discipline, :visit_type,
             :scheduled_at, :started_at, :ended_at,
             :narrative, :vitals, :pain_score,
             :billable, :visit_code, :created_at, :updated_at
end
