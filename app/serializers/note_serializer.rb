class NoteSerializer
  include JSONAPI::Serializer
  attributes :patient_id, :author_user_id, :author_role,
             :body, :source, :urgency, :read_at, :created_at, :updated_at
end
