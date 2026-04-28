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
        body  = params[:text].to_s.strip
        audio = params[:audio]
        return render_err(:unprocessable_entity, "message_empty") if body.blank? && audio.blank?
        return render_err(:unprocessable_entity, "message_too_long", limit: MAX_BODY_LENGTH) if body.length > MAX_BODY_LENGTH

        patient = Patient.unscoped.find(params[:patient_id])
        return render_err(:forbidden, "wrong_agency") unless patient.agency_id == @user.agency_id

        ActsAsTenant.with_tenant(patient.agency) do
          Current.agency           = patient.agency
          Current.agent_id         = (@user.role_names.first || "rn")
          Current.agent_session_id = "clin-#{SecureRandom.hex(3)}"

          # HosAlivio reads every clinician message and decides
          # audience (team vs family) + action (which agent to fire).
          # Build the note first (unsaved) so the brain has the same
          # context the chart sees, then save with the brain-decided
          # clinician_only so Cable broadcasts to the right audience.
          note = patient.notes.build(
            agency:         patient.agency,
            author_user:    @user,
            author_role:    (@user.role_names.first || "rn"),
            body:           body,
            source:         (audio.present? ? :voice : :text),
            urgency:        normalize_urgency(params[:urgency]),
            clinician_only: true   # safe default; brain may flip below
          )

          decision = HosalivioBrain.classify_clinician_message(note: note, requester: @user)

          # Belt-and-suspenders: if the body looks like a question (ends
          # with "?" or starts with a clear interrogative) and the LLM
          # still classified it as no_action, override to answer_question
          # so HosAlivio replies. The LLM occasionally misses phrasings
          # the prompt's examples don't cover.
          if decision[:action].to_s == "no_action" && looks_like_question?(body)
            decision = decision.merge(action: "answer_question")
          end

          note.clinician_only = (decision[:audience] == "team")
          # If the brain rewrote the body (e.g. 'let Carlos know that …'
          # → 'I just left, she is resting comfortably'), use the cleaned
          # version so Carlos sees a direct DM-style note from Pascal,
          # not Pascal's instruction-to-HosAlivio prefix.
          note.body = decision[:body_rewrite] if decision[:body_rewrite].present?
          note.audio.attach(audio) if audio.present?
          note.save!

          notify_mentioned_users(note, body, patient) if note.clinician_only

          if decision[:action].present? && decision[:action] != "no_action"
            ClinicianDispatcher.execute(
              note:      note,
              requester: @user,
              action:    decision[:action],
              ack:       decision[:ack]
            )
          end

          render json: { status: "ok", id: note.id, clinician_only: note.clinician_only,
                         audience: decision[:audience], action: decision[:action],
                         source: decision[:source] }, status: :created
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

      INTERROGATIVES = %w[who what when where why how is has does can should will which are who's what's].freeze

      def looks_like_question?(body)
        s = body.to_s.strip
        return false if s.empty?
        return true if s.end_with?("?")
        first = s.split(/\s+/, 2).first.to_s.downcase
        INTERROGATIVES.include?(first)
      end

      # Scan an internal team message for @FirstName tokens, resolve each
      # to a real user in the same agency, and write a Notification so
      # their bell-icon badge increments. Skips the author so Esther
      # doesn't ping herself by writing "@Esther" in her own message.
      def notify_mentioned_users(note, body, patient)
        first_names = body.to_s.scan(/@(\w+)/).flatten.map(&:downcase).uniq
        return if first_names.empty?
        first_names.each do |fn|
          target = User.where(agency: patient.agency, active: true)
                       .where("LOWER(full_name) LIKE ?", "#{fn} %")
                       .where.not(id: @user.id)
                       .first
          next unless target
          Notification.create!(
            agency:  patient.agency,
            user:    target,
            kind:    "mentioned",
            title:   "#{@user.full_name} mentioned you in #{patient.full_name}'s chart",
            linked:  note
          )
        end
      end

      def render_err(status, code, **extra)
        render json: { error: code }.merge(extra.compact), status: status
      end
    end
  end
end
