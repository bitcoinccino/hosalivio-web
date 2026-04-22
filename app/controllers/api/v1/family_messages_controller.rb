module Api
  module V1
    # Inbound channel for the family-facing chat UI.
    # Deliberately does NOT inherit from BaseController — the family UI has no JWT.
    # In dev this is open on localhost; in production, gate behind a family session
    # (Devise user with family_access: true, scoped to one patient_id).
    class FamilyMessagesController < ActionController::API
      include ActionController::Cookies
      rescue_from ActiveRecord::RecordNotFound, with: -> { render_err(:not_found, "not_found") }
      rescue_from ActiveRecord::RecordInvalid,  with: ->(e) { render_err(:unprocessable_entity, "invalid", errors: e.record.errors.full_messages) }

      before_action :authorize_family_session!

      # Real family chat messages are short and emotional, not essays. 2000 chars
      # is ~400 words, generous for a distressed relative. Blocks transcript
      # dumps and copy-paste accidents from polluting the chart.
      MAX_BODY_LENGTH = 2_000

      def create
        patient = Patient.unscoped.find(params[:patient_id])
        unless @family_user.patient_id == patient.id
          return render_err(:forbidden, "not_your_patient")
        end

        body = note_body
        if body.length > MAX_BODY_LENGTH
          return render_err(:unprocessable_entity, "message_too_long",
                            limit: MAX_BODY_LENGTH, length: body.length,
                            hint: "Family messages should be short. For longer notes, call the branch triage line.")
        end
        return render_err(:unprocessable_entity, "message_empty") if body.blank?

        # Reject the known developer-transcript fingerprint outright. `❯` and
        # `⏺` are Claude Code CLI markers; a real family member doesn't type them.
        if body.match?(/[❯⏺▎]/)
          return render_err(:unprocessable_entity, "non_family_content",
                            hint: "This looks like a copy-paste from a terminal, not a family message.")
        end

        ActsAsTenant.with_tenant(patient.agency) do
          Current.agency           = patient.agency
          Current.agent_id         = "front_door_inbound"
          Current.agent_session_id = request.headers["X-HosAlivio-Session"] || "family-ui"

          note = patient.notes.create!(
            agency:      patient.agency,
            author_role: "family",
            body:        body,
            source:      (params[:source].presence || "text"),
            urgency:     (params[:urgency].presence || "normal")
          )

          # Nudge Lucia (Front Door) and any other listeners with a typed broadcast.
          # Clients already subscribed to patient:{id} will receive this immediately.
          # Note model auto-broadcasts to patient:{id} on create_commit.
          # Wake Lucia — she classifies, escalates, and replies in a background job.
          LuciaTriageJob.perform_later(note.id)

          render json: { status: "ok", id: note.id, urgency: note.urgency }, status: :created
        end
      end

      private

      # Gate the endpoint behind a real signed-in family Devise user.
      # Session cookie (from sign-in via /users/sign_in) is the trust boundary;
      # the user must have family_access=true and a patient_id matching the
      # URL. Without that, the request is rejected before any Note is written.
      def authorize_family_session!
        warden = request.env["warden"]
        @family_user = warden && warden.authenticate(scope: :user)
        unless @family_user && @family_user.family_access? && @family_user.patient_id.present?
          render_err(:unauthorized, "family_session_required",
                     hint: "Sign in as the patient's family member first.")
        end
      end

      def note_body
        (params[:text].presence || params[:body].presence || params[:voice_transcript].presence).to_s.strip
      end

      def render_err(status, code, **extra)
        render json: { error: code }.merge(extra), status: status
      end
    end
  end
end
