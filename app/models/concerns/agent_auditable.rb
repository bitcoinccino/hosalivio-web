# Auto-logs an AgentEvent on every commit when the request context has
# Current.agent_id set (i.e. the write came from an OpenClaw agent, not a human).
module AgentAuditable
  extend ActiveSupport::Concern

  included do
    after_commit :log_agent_event_if_agent_driven
  end

  private

  def log_agent_event_if_agent_driven
    return if is_a?(AgentEvent)                       # prevent infinite loop
    return unless Current.agent_id.present?
    return unless respond_to?(:agency_id) && agency_id.present?

    AgentEvent.create!(
      agency_id:        agency_id,
      agent_id:         Current.agent_id,
      agent_session_id: Current.agent_session_id,
      action:           agent_event_action,
      subject:          self,
      change_set:       (saved_changes || {}).except("updated_at", "created_at"),
      happened_at:      Time.current
    )
  end

  def agent_event_action
    return "destroy" if destroyed?
    return "create"  if previously_new_record?
    "update"
  end
end
