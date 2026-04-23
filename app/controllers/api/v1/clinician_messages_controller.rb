module Api
  module V1
    # Clinician-side companion to FamilyMessagesController.
    # POST a message into a patient's chat thread as the signed-in clinician.
    # Saved with author_user_id (so the chat shows their real name) and
    # author_role from their primary role.
    class ClinicianMessagesController < ActionController::API
      include ActionController::Cookies

      MAX_BODY_LENGTH = 4_000

      rescue_from ActiveRecord::RecordNotFound, with: -> { render_err(:not_found, "not_found") }
      rescue_from ActiveRecord::RecordInvalid,  with: ->(e) { render_err(:unprocessable_entity, "invalid", errors: e.record.errors.full_messages) }

      before_action :authorize_clinician_session!

      def create
        body = params[:text].to_s.strip
        return render_err(:unprocessable_entity, "message_empty")    if body.blank?
        return render_err(:unprocessable_entity, "message_too_long", limit: MAX_BODY_LENGTH) if body.length > MAX_BODY_LENGTH

        patient = Patient.unscoped.find(params[:patient_id])
        return render_err(:forbidden, "wrong_agency") unless patient.agency_id == @user.agency_id

        ActsAsTenant.with_tenant(patient.agency) do
          Current.agency           = patient.agency
          Current.agent_id         = (@user.role_names.first || "rn")
          Current.agent_session_id = "clin-#{SecureRandom.hex(3)}"

          internal = ActiveModel::Type::Boolean.new.cast(params[:internal])
          note = patient.notes.create!(
            agency:         patient.agency,
            author_user:    @user,
            author_role:    (@user.role_names.first || "rn"),
            body:           body,
            source:         :text,
            urgency:        normalize_urgency(params[:urgency]),
            clinician_only: internal
          )
          render json: { status: "ok", id: note.id, clinician_only: note.clinician_only }, status: :created
        end
      end

      private

      def authorize_clinician_session!
        warden = request.env["warden"]
        @user = warden && warden.authenticate(scope: :user)
        unless @user && !@user.family_access?
          render_err(:unauthorized, "clinician_session_required",
                     hint: "Clinicians only — sign in as a clinical role.")
        end
      end

      def normalize_urgency(raw)
        v = raw.to_s.downcase
        %w[normal urgent crisis].include?(v) ? v : "normal"
      end

      def render_err(status, code, **extra)
        render json: { error: code }.merge(extra.compact), status: status
      end
    end
  end
end
