class AgentEventSerializer
  include JSONAPI::Serializer
  attributes :agent_id, :agent_session_id, :action,
             :subject_type, :subject_id, :happened_at, :created_at, :change_set
end
