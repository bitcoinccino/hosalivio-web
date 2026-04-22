module Api
  module V1
    # POST /api/v1/transcribe
    #
    # Accepts:
    #   audio     (multipart file, required)
    #   language  (2-letter ISO code, optional — hint to Whisper)
    #   prompt    (optional vocabulary hint, e.g. "HosAlivio, Pascal, morphine")
    #
    # Auth: requires a signed-in Devise user (family or clinician) so random
    # visitors can't burn the OpenAI budget by spamming requests.
    class TranscriptionsController < ActionController::API
      include ActionController::Cookies

      rescue_from ActiveRecord::RecordNotFound, with: -> { render_err(:not_found, "not_found") }

      before_action :authorize_session!

      def create
        unless params[:audio].respond_to?(:read)
          return render_err(:unprocessable_entity, "missing_audio", hint: "Attach an audio file as 'audio'.")
        end

        result = WhisperTranscriber.call(
          audio:    params[:audio],
          language: params[:language],
          prompt:   params[:prompt]
        )

        if result.ok?
          render json: {
            status: "ok",
            text:   result.text,
            duration_seconds: result.duration_seconds,
            provider: "whisper-1"
          }, status: :ok
        else
          Rails.logger.info("[TranscriptionsController] failed: #{result.error} (#{result.respond_to?(:message) ? result.message : ''})")
          render_err(:service_unavailable, result.error,
                     hint: result.respond_to?(:message) ? result.message : nil)
        end
      end

      private

      def authorize_session!
        warden = request.env["warden"]
        user = warden && warden.authenticate(scope: :user)
        return if user
        render_err(:unauthorized, "login_required",
                   hint: "Sign in to use voice transcription.")
      end

      def render_err(status, code, **extra)
        render json: { error: code }.merge(extra.compact), status: status
      end
    end
  end
end
