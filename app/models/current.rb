class Current < ActiveSupport::CurrentAttributes
  # Request-scoped context. Populated by ApplicationController (web) and
  # Api::BaseController (agents) on each request.
  attribute :user, :agency, :agent_id, :agent_session_id, :request_id
end
