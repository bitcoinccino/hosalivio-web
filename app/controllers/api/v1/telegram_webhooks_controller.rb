module Api
  module V1
    # Receives updates from the HosAlivio Telegram bot. Routes
    # reply-to-message events back into the right patient chat as
    # a Note authored by the matched clinician.
    #
    # Auth: Telegram supports a `secret_token` header on webhook
    # registration. Compare against TELEGRAM_WEBHOOK_SECRET; reject
    # with 401 on mismatch.
    #
    # HIPAA: Telegram is NOT BAA-covered. Replies are gated by
    # Agency#features["allow_telegram_replies"] (default false). When
    # off, we reply to the user via the bot with a "use HosAlivio for
    # clinical content" notice and drop the message.
    class TelegramWebhooksController < ActionController::API
      before_action :verify_secret!

      def receive
        update = params.to_unsafe_h
        msg    = update["message"] || update["edited_message"]
        return head(:ok) if msg.nil?  # ignore non-message updates (callback queries, etc.)

        chat_id = msg.dig("chat", "id")&.to_s
        text    = msg["text"].to_s.strip
        reply_to_msg_id = msg.dig("reply_to_message", "message_id")&.to_i

        return head(:ok) if chat_id.blank? || text.blank?

        user = lookup_user_by_chat_id(chat_id)
        return bot_reply(chat_id, "Your Telegram is not linked to a HosAlivio account. Sign in and add this chat ID in /profiles/edit.") if user.nil?

        unless user.agency&.features&.dig("allow_telegram_replies")
          bot_reply(chat_id, "Telegram replies are disabled for your agency. Open HosAlivio to respond.")
          return head(:ok)
        end

        ping = reply_to_msg_id && OutboundPing.unscoped.find_by(telegram_message_id: reply_to_msg_id)
        if ping.nil?
          bot_reply(chat_id, "Long-press a HosAlivio ping and tap Reply, then send your message. Without that link I can't tell which patient you mean.")
          return head(:ok)
        end

        if ping.user_id != user.id
          bot_reply(chat_id, "That ping wasn't sent to you. I can't route a reply you didn't receive.")
          return head(:ok)
        end

        post_reply_into_patient_chat(user: user, ping: ping, text: text)
        bot_reply(chat_id, "Posted to #{ping.payload["patient_id"] ? "the chart" : "HosAlivio"}. Carlos and the team can see it now.")
        head :ok
      rescue => e
        Rails.logger.warn("[TelegramWebhooks] #{e.class}: #{e.message}")
        head :ok  # always 200 so Telegram doesn't retry-storm
      end

      private

      def verify_secret!
        secret = ENV["TELEGRAM_WEBHOOK_SECRET"].to_s
        if secret.blank?
          render(json: { error: "secret_not_configured" }, status: :service_unavailable) and return
        end
        token = request.headers["X-Telegram-Bot-Api-Secret-Token"].to_s
        unless ActiveSupport::SecurityUtils.secure_compare(token, secret)
          render(json: { error: "unauthorized" }, status: :unauthorized) and return
        end
      end

      def lookup_user_by_chat_id(chat_id)
        # The chat_id lives inside notification_channels JSONB. Use a
        # JSONB-text lookup so the query is index-eligible. There can
        # only be one user per chat_id in practice; if there were
        # collisions the first match wins (deterministic).
        User.where("notification_channels -> 'telegram' ->> 'chat_id' = ?", chat_id.to_s).first
      end

      # Posts the inbound Telegram text as a Note in the matched
      # patient's chat. Family-visible so Carlos sees it instantly.
      # source: "telegram" lets the chat partial render a small
      # "via Telegram" footnote on the bubble. Fires the existing
      # broadcast + outbound-ping pipelines automatically.
      def post_reply_into_patient_chat(user:, ping:, text:)
        patient = ping.payload["patient_id"] && Patient.unscoped.find_by(id: ping.payload["patient_id"])
        patient ||= Note.unscoped.find_by(id: ping.payload["note_id"])&.patient
        raise ActiveRecord::RecordNotFound if patient.nil?

        Note.create!(
          agency:         patient.agency,
          patient:        patient,
          author_user:    user,
          author_role:    user.role_names.first || "rn",
          body:           text,
          urgency:        "normal",
          source:         "telegram",
          clinician_only: false  # family-visible — that's the point of the reply
        )
        AgentEvent.create!(
          agency:      patient.agency,
          agent_id:    "telegram_inbound",
          action:      "reply_received",
          subject:     patient,
          happened_at: Time.current,
          change_set: {
            user_id:           user.id,
            ping_id:           ping.id,
            chars:             text.length
          }
        )
      end

      def bot_reply(chat_id, text)
        token = ENV["TELEGRAM_BOT_TOKEN"].to_s
        return if token.blank?
        uri = URI("https://api.telegram.org/bot#{token}/sendMessage")
        Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 10) do |http|
          req = Net::HTTP::Post.new(uri)
          req["content-type"] = "application/json"
          req.body = { chat_id: chat_id, text: text }.to_json
          http.request(req)
        end
      rescue => e
        Rails.logger.warn("[TelegramWebhooks#bot_reply] #{e.class}: #{e.message}")
      end
    end
  end
end
