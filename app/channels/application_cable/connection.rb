module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :principal

    def connect
      self.principal = find_verified_principal
    end

    private

    def find_verified_principal
      # Agent via JWT (query string for dev; header for prod)
      token = request.params[:token].presence ||
              request.headers["Authorization"].to_s.sub(/\ABearer\s+/, "")
      if (payload = AgentToken.decode(token))
        agency = Agency.find_by(id: payload[:agency_id])
        return AgentPrincipal.new(role: payload[:role], agency: agency) if agency
      end

      # Dev fallback: allow unauth'd connection so the internal dashboard loads.
      # In production, reject_unauthorized_connection here.
      return :anonymous if Rails.env.development? || Rails.env.test?

      reject_unauthorized_connection
    end
  end
end
