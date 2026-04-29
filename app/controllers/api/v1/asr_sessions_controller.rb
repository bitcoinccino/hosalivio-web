module Api
  module V1
    # Routes the visit recording page to the right ASR backend based
    # on the patient's preferred language. Returns the connection
    # info the browser needs to open a streaming session, including
    # a short-lived Deepgram API key so we never expose the long-
    # lived account key to the browser.
    #
    # Provider matrix:
    #   en, es, pt -> deepgram (Nova-2-medical + diarization)
    #   ht         -> web_speech (Deepgram lacks Haitian Creole)
    #   other      -> web_speech (safe fallback)
    #
    # When Deepgram is unreachable / unconfigured, the response falls
    # back to web_speech so the recording page never breaks; the
    # client just uses the existing Web Speech path.
    class AsrSessionsController < ActionController::API
      include ActionController::Cookies

      before_action :authenticate_clinician!

      DEEPGRAM_LANGUAGES = %w[en es pt].freeze

      def create
        patient = Patient.unscoped.find(params[:patient_id])
        unless patient.agency_id == @user.agency_id
          render(json: { error: "forbidden" }, status: :forbidden) and return
        end

        lang_code = patient.preferred_language.to_s.presence || "en"

        if DEEPGRAM_LANGUAGES.include?(lang_code)
          issued = DeepgramTokenIssuer.issue(
            comment: "hosalivio-#{@user.id}-#{patient.id}",
            ttl:     3_600,
            scopes:  %w[usage:write]
          )
          if issued.present?
            render(json: deepgram_payload(lang_code, issued)) and return
          end
        end

        render json: web_speech_payload(lang_code)
      end

      private

      def authenticate_clinician!
        warden = request.env["warden"]
        @user = warden && warden.authenticate(scope: :user)
        unless @user && !@user.family_access?
          render json: { error: "clinician_session_required" }, status: :unauthorized
        end
      end

      def deepgram_payload(lang_code, issued)
        {
          provider:    "deepgram",
          token:       issued["key"],
          expires_at:  issued["expiration_date"],
          model:       "nova-2-medical",
          language:    map_to_bcp47(lang_code),
          diarize:     true,
          # Deepgram realtime endpoint. Query params travel with the
          # WebSocket URL. Smart format + punctuate + interim_results
          # give the live-transcript-overlay UX clinicians expect.
          websocket_url: build_deepgram_url(lang_code)
        }
      end

      def web_speech_payload(lang_code)
        {
          provider: "web_speech",
          language: map_to_bcp47(lang_code)
        }
      end

      def build_deepgram_url(lang_code)
        params = {
          model:           "nova-2-medical",
          language:        map_to_bcp47(lang_code),
          diarize:         true,
          interim_results: true,
          punctuate:       true,
          smart_format:    true,
          # MediaRecorder typically gives webm/opus; let Deepgram detect
          # from the container headers (no encoding= param needed when
          # streaming a recognized container).
          endpointing:     500
        }
        "wss://api.deepgram.com/v1/listen?#{params.to_query}"
      end

      def map_to_bcp47(code)
        {
          "en" => "en-US",
          "es" => "es",         # Deepgram uses bare "es" for multi-region
          "pt" => "pt-BR",
          "ht" => "ht-HT"
        }[code.to_s] || "en-US"
      end
    end
  end
end
