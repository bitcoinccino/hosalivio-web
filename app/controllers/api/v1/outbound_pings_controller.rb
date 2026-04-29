module Api
  module V1
    # Cross-tenant API the openclaw `hosalivio_clinician_ping.js`
    # poller uses to fetch pending pings and report delivery. Auth
    # is a shared bearer secret (OPENCLAW_PINGS_SECRET env var)
    # rather than the per-agency AgentToken, because the poller is
    # infrastructure that serves every tenant. Skip the BaseController
    # tenant scoping since this controller intentionally crosses
    # agency boundaries.
    class OutboundPingsController < ActionController::API
      before_action :authenticate_infra_secret!

      # GET /api/v1/outbound_pings/pending
      # Returns up to `limit` (default 50) undelivered, non-expired
      # pings across all tenants, with the recipient user's channel
      # preferences and quiet-hours config inlined so the openclaw
      # script doesn't need a second round-trip per row.
      def pending
        limit = (params[:limit] || 50).to_i.clamp(1, 200)
        rows  = OutboundPing.unscoped
                            .where(delivered_at: nil)
                            .where("link_expires_at > ?", Time.current)
                            .order(:created_at)
                            .limit(limit)
                            .includes(:user, :agency)

        render json: {
          pings: rows.map { |p| serialize(p) },
          fetched_at: Time.current.iso8601
        }
      end

      # POST /api/v1/outbound_pings/:id/delivered
      # Marks a ping as delivered + records which channels succeeded.
      # If `error` is present, store that on last_error and DO NOT
      # mark delivered (so the poller retries on the next pass).
      def delivered
        ping = OutboundPing.unscoped.find(params[:id])
        if (err = params[:error].to_s.presence)
          ping.update!(last_error: err)
          return render json: { ok: true, retried: true }
        end
        channels = Array(params[:channels]).map(&:to_s).uniq.presence || []
        attrs = {
          delivered_at:       Time.current,
          delivered_channels: channels
        }
        # Telegram's sendMessage returns the message_id of the message
        # we just posted. The openclaw poller captures it and pipes it
        # back here so future Telegram replies (when the RN long-presses
        # → Reply on the ping) can be threaded back to this patient.
        if (tg_msg_id = params[:telegram_message_id]).present?
          attrs[:telegram_message_id] = tg_msg_id.to_i
        end
        ping.update!(attrs)
        render json: { ok: true, delivered_channels: channels }
      end

      private

      def authenticate_infra_secret!
        secret = ENV["OPENCLAW_PINGS_SECRET"].to_s
        token  = request.headers["Authorization"].to_s.sub(/\ABearer\s+/, "")
        if secret.blank?
          render(json: { error: "secret_not_configured" }, status: :service_unavailable) and return
        end
        unless ActiveSupport::SecurityUtils.secure_compare(token, secret)
          render(json: { error: "unauthorized" }, status: :unauthorized) and return
        end
      end

      def serialize(p)
        u = p.user
        {
          id:              p.id,
          kind:            p.kind,
          preview:         p.preview,
          link_token:      p.link_token,
          link_expires_at: p.link_expires_at.iso8601,
          deeplink:        deeplink_for(p),
          crisis:          p.crisis?,
          created_at:      p.created_at.iso8601,
          recipient: {
            id:                  u.id,
            full_name:           u.full_name,
            in_quiet_hours:      u.in_quiet_hours?,
            notification_channels: u.notification_channels
          },
          agency: {
            id:    p.agency.id,
            name:  p.agency.name,
            slug:  p.agency.slug
          }
        }
      end

      def deeplink_for(ping)
        host = ENV.fetch("HOSALIVIO_PUBLIC_HOST", "hosalivio.app")
        "https://#{host}/inbox?t=#{ping.link_token}"
      end
    end
  end
end
