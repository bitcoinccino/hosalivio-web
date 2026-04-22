module Api
  module V1
    class BaseController < ActionController::API
      include Pundit::Authorization

      before_action :authenticate_agent!
      before_action :scope_to_tenant

      # after_action :verify_authorized     # enable once all controllers authorize explicitly
      # after_action :verify_policy_scoped, only: :index

      rescue_from Pundit::NotAuthorizedError, with: :forbidden!
      rescue_from ActiveRecord::RecordNotFound, with: :not_found!
      rescue_from ActiveRecord::RecordInvalid,  with: :invalid_record!

      private

      def authenticate_agent!
        token   = request.headers["Authorization"].to_s.sub(/\ABearer\s+/, "")
        payload = AgentToken.decode(token)
        return render_error(:unauthorized, "invalid_token") if payload.nil?

        agency = Agency.find_by(id: payload[:agency_id])
        return render_error(:unauthorized, "agency_not_found") if agency.nil?

        Current.agency           = agency
        Current.agent_id         = payload[:role]
        Current.agent_session_id = request.headers["X-OpenClaw-Session-Id"]
        Current.request_id       = request.request_id
      end

      def scope_to_tenant
        ActsAsTenant.current_tenant = Current.agency
      end

      # Pundit user is the AgentPrincipal, not a User record
      def pundit_user
        AgentPrincipal.new(role: Current.agent_id, agency: Current.agency)
      end

      # --- error renderers -------------------------------------------------

      def forbidden!(exception = nil)
        render_error(:forbidden, "forbidden",
                     policy: exception&.policy&.class&.name,
                     query:  exception&.query)
      end

      def not_found!(_e)
        render_error(:not_found, "not_found")
      end

      def invalid_record!(e)
        render_error(:unprocessable_entity, "invalid",
                     errors: e.record.errors.full_messages)
      end

      def render_error(status, code, **extra)
        render json: { error: code }.merge(extra), status: status
      end
    end
  end
end
