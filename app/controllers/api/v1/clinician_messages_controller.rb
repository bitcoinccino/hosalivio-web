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

          # Keep the post path fast: classify common chat intents locally,
          # save/broadcast the human note immediately, then let HosAlivio
          # answer or dispatch from a background job.
          parent = reply_parent_for(patient)

          note = patient.notes.build(
            agency:         patient.agency,
            author_user:    @user,
            author_role:    (@user.role_names.first || "rn"),
            body:           body,
            source:         (audio.present? ? :voice : :text),
            urgency:        normalize_urgency(params[:urgency]),
            clinician_only: true,  # safe default; brain may flip below
            parent_note:    parent
          )

          # A threaded reply is a plain human message: it inherits the parent's
          # visibility (Note model) and does NOT wake the AI dispatcher — threads
          # stay human-to-human. Notify the thread + any @mentions, then return.
          if parent
            note.audio.attach(audio) if audio.present?
            note.save!
            notify_mentioned_users(note, body, patient) if note.clinician_only
            notify_thread_participants(note, parent)
            # @HosAlivio inside a team thread: let the dispatcher answer/act.
            # Its reply threads under this conversation's root (post_ack). Gated
            # to team-only threads so a [HOSALIVIO_ACK] note never lands in a
            # family-visible thread.
            # @HosAlivio mention wakes the dispatcher. A bare "yes"/"cancel"
            # in the thread also wakes it when a relay preview is awaiting
            # confirmation, so the clinician doesn't have to re-tag the bot.
            # !! so the JSON is a strict true/false (relay_confirmation_for can
            # return nil), which the client checks with === false.
            wake_ai = !!(note.clinician_only && (ClinicianDispatcher.mentions_hosalivio?(body) ||
                                                 ClinicianDispatcher.relay_confirmation_for(note)))
            ClinicianMessageResponseJob.perform_later(note.id, @user.id, "classify") if wake_ai
            # ai_reply_expected lets the chat UI keep or drop the "thinking"
            # indicator: a plain thread reply gets no AI reply, so the dots
            # shouldn't hang.
            return render json: { status: "ok", id: note.id, parent_note_id: parent.id,
                                  clinician_only: note.clinician_only,
                                  ai_reply_expected: wake_ai }, status: :created
          end

          decision = fast_decision_for(body, patient)
          note.clinician_only = (decision[:audience] == "team")
          note.audio.attach(audio) if audio.present?
          note.save!

          notify_mentioned_users(note, body, patient) if note.clinician_only

          ai_reply_expected = decision[:action].present? && decision[:action] != "no_action"
          ClinicianMessageResponseJob.perform_later(note.id, @user.id, decision[:action], decision[:ack]) if ai_reply_expected

          render json: { status: "ok", id: note.id, clinician_only: note.clinician_only,
                         audience: decision[:audience], action: decision[:action],
                         source: decision[:source], ai_reply_expected: ai_reply_expected }, status: :created
        end
      end

      # Send/Cancel buttons on a relay preview hit this instead of posting a
      # "yes" chat message — so confirming is silent (no extra bubble). We
      # act on the patient's pending offer directly via the dispatch job.
      def confirm_relay
        patient = Patient.unscoped.find(params[:patient_id])
        return render_err(:forbidden, "wrong_agency") unless patient.agency_id == @user.agency_id

        decision = params[:decision].to_s == "cancel" ? "cancel_relay" : "confirm_relay"

        # Optional edited draft from the Edit affordance — send this instead of
        # the original. Only on a confirm; ignored on cancel or when too long.
        edited = params[:message].to_s.strip
        edited = nil if edited.empty? || edited.length > MAX_BODY_LENGTH || decision == "cancel_relay"

        ActsAsTenant.with_tenant(patient.agency) do
          offer = ClinicianDispatcher.pending_relay_offer(patient)
          return render json: { status: "no_pending_offer" }, status: :ok unless offer

          # Drive the job off the offer note itself: the dispatcher reads the
          # patient/agency from it and resolves the drafted message from the
          # offer payload (or the edited override) — no clinician reply note.
          ClinicianMessageResponseJob.perform_later(
            offer.id, @user.id, decision, nil, edited ? { "message" => edited } : nil
          )
        end

        render json: { status: "ok", decision: decision, edited: edited.present? }, status: :created
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

      def fast_decision_for(body, patient)
        action = ClinicianDispatcher.intent_for(body)
        action ||= continuation_action_for(body, patient)
        action ||= "answer_question" if looks_like_question?(body) ||
                                        status_context_request?(body) ||
                                        short_continuation_reply?(body, patient)
        action ||= "classify"

        {
          audience: ClinicianDispatcher.classify_audience(body).to_s,
          action: action,
          ack: nil,
          source: "fast:heuristic"
        }
      end

      INTERROGATIVES = %w[who what when where why how is has does can should will which are who's what's].freeze
      AFFIRMATIVES   = %w[yes yeah yep yup ok okay sure please correct right confirm].freeze
      NEGATIVES      = %w[no nope thanks thank].freeze
      CONTEXT_REPLY_MAX_WORDS = 6
      # An accepted offer ("yes") only routes to the insurance team when the
      # offer was *specifically* about insurance/coverage. Requires a
      # verify/check verb within 40 chars of an insurance noun (either order),
      # mirroring ClinicianDispatcher::INTENT_MAP. A bare "verify" — as in
      # "to verify completion status … ping her" — must NOT trigger insurance;
      # those affirmations fall through to answer_question so the brain can
      # ping the person actually offered (e.g. the DON).
      INSURANCE_OFFER_RE = Regexp.union(
        /\b(verify|check|confirm|review|file)\b.{0,40}\b(insurance|insured|coverage|medicare|medicaid|eligibility|noe)\b/i,
        /\b(insurance|insured|coverage|medicare|medicaid|eligibility|noe)\b.{0,40}\b(verify|check|confirm|review|file)\b/i
      )

      def looks_like_question?(body)
        s = body.to_s.strip
        return false if s.empty?
        return true if s.end_with?("?")
        first = s.split(/\s+/, 2).first.to_s.downcase.gsub(/[[:punct:]]+$/, "")
        INTERROGATIVES.include?(first)
      end

      def status_context_request?(body)
        s = body.to_s.downcase
        return false if s.blank?
        return true if s.match?(/\b(patient|pt|resident|case|chart)\b/) &&
                       s.match?(/\b(status|condition|declin|dying|actively dying|transitioning|death|life|critical|urgent|emergency)\b/)
        return true if s.match?(/\b(status|condition)\b/) &&
                       s.match?(/\b(matter of|life or death|death or life|no confusion|confusion)\b/)
        false
      end

      def continuation_action_for(body, patient)
        return nil unless affirmative_reply?(body)
        last_offer = recent_hosalivio_offer(patient)
        return nil unless last_offer
        return "verify_insurance" if last_offer.body.to_s.match?(INSURANCE_OFFER_RE)

        nil
      end

      def affirmative_reply?(body)
        words = body.to_s.strip.split(/\s+/)
        return false if words.empty? || words.length > CONTEXT_REPLY_MAX_WORDS
        first = words.first.to_s.downcase.gsub(/[[:punct:]]+$/, "")
        AFFIRMATIVES.include?(first)
      end

      OFFER_PHRASING_RE = /\b(want me to|should i|would you like me to|ping|notify|connect|flag|route)\b/i

      # An OPEN offer is only the LATEST HosAlivio message — if a dispatch ack
      # or answer came after it, the offer was already acted on. Returning a
      # stale offer here let a second "yes" re-fire the same action, looping
      # the dispatch (e.g. "Kendra (Insurance) asked to verify insurance"
      # over and over). Anchoring to the latest message closes the offer once.
      def recent_hosalivio_offer(patient)
        return nil if patient.nil?
        latest = patient.notes
                        .where(author_role: "admissions", source: "system")
                        .where("created_at > ?", 30.minutes.ago)
                        .order(created_at: :desc)
                        .first
        latest if latest&.body.to_s.match?(OFFER_PHRASING_RE)
      end

      # True when the body is a short reply that's most likely a
      # continuation of HosAlivio's prior turn. Mirror of the family-
      # side context_reply? so clinicians get the same context-aware
      # treatment ("yes ping admissions" -> brain sees recent offer
      # -> emits notify directive -> dispatcher executes).
      def short_continuation_reply?(body, patient)
        return false if patient.nil?
        s = body.to_s.strip
        words = s.split(/\s+/)
        return false if words.empty? || words.length > CONTEXT_REPLY_MAX_WORDS
        first = words.first.to_s.downcase.gsub(/[[:punct:]]+$/, "")
        return true if AFFIRMATIVES.include?(first) || NEGATIVES.include?(first)
        # Has a recent HosAlivio reply in the thread (within 30 min)?
        patient.notes
               .where(author_role: "admissions", source: "system")
               .where("created_at > ?", 30.minutes.ago)
               .exists?
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

      # Resolve a valid reply target: a top-level (root) note for this patient.
      # roots-only enforces the one-level-deep rule at the door; an unknown id
      # returns nil so the message just posts as a new top-level note.
      def reply_parent_for(patient)
        pid = params[:parent_note_id].presence
        return nil unless pid
        patient.notes.roots.find_by(id: pid)
      end

      # Ping the people already in this thread (root author + prior repliers)
      # when a new clinician reply lands, minus the replier and family users
      # (family hear it live in their chat, not via the clinician bell).
      def notify_thread_participants(reply, parent)
        ids = ([ parent.author_user_id ] + parent.replies.pluck(:author_user_id)).compact.uniq
        ids.delete(@user.id)
        return if ids.empty?
        User.where(id: ids, agency: parent.agency, active: true, family_access: false).find_each do |u|
          Notification.create!(
            agency: parent.agency, user: u, kind: "thread_reply",
            title:  "#{@user.full_name} replied in #{parent.patient.full_name}'s chat",
            linked: reply
          )
        end
      end

      def render_err(status, code, **extra)
        render json: { error: code }.merge(extra.compact), status: status
      end
    end
  end
end
