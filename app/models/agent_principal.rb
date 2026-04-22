# Pundit "user" stand-in for agent-authenticated API requests.
# Not persisted. Constructed from the JWT payload on each request.
AgentPrincipal = Struct.new(:role, :agency, keyword_init: true) do
  def admin?          = role == "admin"
  def has_role?(name) = role == name.to_s
  def agency_id       = agency&.id
end
