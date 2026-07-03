class VisitsController < ApplicationController
  before_action :authenticate_user!
  before_action :redirect_family_users
  before_action :set_visit, only: [ :show, :edit, :update, :destroy, :begin, :finish, :record, :discard, :route_to_md, :sign_note, :regenerate_summary, :apply_intake_suggestions, :dismiss_intake_suggestions ]
  before_action :authorize_visit_scheduler!, only: [ :new, :create ]
  before_action :authorize_visit_writer!,    only: [ :update, :destroy, :begin, :finish, :record, :discard, :route_to_md, :sign_note, :regenerate_summary, :apply_intake_suggestions, :dismiss_intake_suggestions ]

  # Staged intake keys that map to Patient columns rather than the intake blob.
  INTAKE_PATIENT_COLUMNS = %w[ code_status caregiver_relationship veteran_status ].freeze

  # GET /visits/new?user_id=&scheduled_at=
  def new
    @visit = Visit.new(
      agency:       current_user.agency,
      user_id:      params[:user_id] || current_user.id,
      scheduled_at: parse_time(params[:scheduled_at]) || default_slot,
      discipline:   params[:discipline] || "rn",
      visit_type:   "routine"
    )
    ActsAsTenant.with_tenant(current_user.agency) do
      @clinicians = agency_clinicians
      @patients   = Patient.order(:mrn)
    end
    render :new, layout: false if request.headers["Turbo-Frame"] || params[:modal]
  end

  def create
    ActsAsTenant.with_tenant(current_user.agency) do
      @visit = Visit.new(visit_params.merge(agency: current_user.agency, agent_authored: false, created_by_user_id: current_user.id))
      if @visit.save
        @visit.deliver_assignment_email!(scheduled_by: current_user)
        redirect_to calendar_path(date: (@visit.scheduled_at || Time.current).to_date),
                    status: :see_other,
                    notice: "Visit scheduled for #{@visit.scheduled_at&.strftime('%a %b %-d, %-l:%M %p')}."
      else
        @clinicians = agency_clinicians
        @patients   = Patient.order(:mrn)
        flash.now[:alert] = @visit.errors.full_messages.to_sentence
        render :new, status: :unprocessable_entity
      end
    end
  end

  def show
    audit_phi_reveal(@visit)
    render :show, layout: false if request.headers["Turbo-Frame"] || params[:modal]
  end

  def edit
    ActsAsTenant.with_tenant(current_user.agency) do
      @clinicians = agency_clinicians
      @patients   = Patient.order(:mrn)

      # Backfill: every admission visit needs its own linked
      # pre-admit eval so the Medicaid pane on the edit page can
      # render. Two paths in:
      #   (1) Claim an existing unlinked draft for this patient
      #       (e.g. one created at partner signup with no visit
      #       attached yet) — avoids duplicate eval rows.
      #   (2) Otherwise create a fresh draft. Each admission visit
      #       gets exactly one eval (Visit has_one :pre_admit_eval),
      #       so previous certified evals on the same patient don't
      #       block this visit's eval from being generated.
      if @visit.visit_type_admission? && @visit.pre_admit_eval.nil?
        # Idempotent claim-or-create, shared with the recording-finish path and
        # guarded by a partial unique index so concurrent edits can't create a
        # second eval for this visit.
        eval_rec = ensure_pre_admit_eval_for(@visit)
        if eval_rec && narrative_for_eval(@visit).present? && !eval_rec.status_certified?
          result = PreAdmitNarrativeExtractor.call(
            narrative:     narrative_for_eval(@visit),
            existing_json: eval_rec.raw_json,
            visit:         @visit,
            patient:       @visit.patient
          )
          eval_rec.update!(raw_json: result.json)
        end
        @visit.reload
      end

      prepare_recorded_admission_visit if params[:just_recorded].to_s == "1"
    end
    render :edit, layout: false if request.headers["Turbo-Frame"] || params[:modal]
  end

  def update
    ActsAsTenant.with_tenant(current_user.agency) do
      # Side-channel: the recording screen's language pill PATCHes here
      # with `patient_preferred_language` set when the RN taps
      # "Set as patient default" while choosing transcription language.
      if (lang = params[:patient_preferred_language].to_s.presence)
        @visit.patient.update!(preferred_language: lang) if Patient::SUPPORTED_LANGUAGES.include?(lang)
      end

      # Lock tiers:
      #   completed visit → assignment + scheduling fields freeze
      #     (audio capture is also done by then).
      #   linked eval certified by MD → narrative joins the lock;
      #     it's now a signed medical record and corrections need a
      #     late-entry note. Until certification, the RN can keep
      #     correcting the polished narrative inline so post-visit
      #     review doesn't require filing an amendment for typos.
      attrs = visit_params
      if @visit.completed_visit?
        attrs = attrs.except(:audio_note,
                             :patient_id, :user_id, :discipline,
                             :scheduled_at, :ended_at,
                             :visit_type, :service_location, :facility_name)
      end
      if @visit.chart_locked?
        attrs = attrs.except(:narrative)
      end

      # Recording / draft review (in_progress): the billing-identity fields are
      # locked for everyone (even schedulers). Changing patient / clinician /
      # role / scheduled start mid-encounter risks misfiled PHI or a broken EVV
      # time marker. End time + location stay editable. visit_type isn't frozen
      # here so the record wizard's type picker (its own PATCH) still works; the
      # draft form's visit_type field is disabled in the UI.
      if @visit.currently_in_progress?
        attrs = attrs.except(:patient_id, :user_id, :discipline, :scheduled_at)
      end

      # Visit metadata (assignment + schedule + type + location) is
      # owned by admissions/admin/DON. Performing clinicians can
      # update narrative + vitals but not the assignment. Strip
      # those fields if a non-scheduler PATCH tries to change them.
      scheduler_roles = %w[admin don admissions]
      recording_type_picker =
        params[:recording_type_picker].to_s == "1" &&
        @visit.user_id == current_user.id &&
        !@visit.completed_visit?
      picked_visit_type = attrs[:visit_type] if recording_type_picker
      unless (current_user.role_names & scheduler_roles).any?
        attrs = attrs.except(:patient_id, :user_id, :discipline,
                             :scheduled_at, :ended_at,
                             :visit_type, :service_location, :facility_name)
        attrs[:visit_type] = picked_visit_type if picked_visit_type.present?
      end

      if @visit.update(attrs.merge(agent_authored: false))
        prepare_recorded_admission_visit if params[:just_recorded].to_s == "1"

        # Two submit buttons on the in-progress edit form share this
        # update action. submit_action=finish chains into the finish
        # flow (stamp ended_at, polish, extractor, route to MD) so
        # the RN's pending narrative + vitals edits ride along
        # instead of being dropped by a separate Finish click.
        if params[:submit_action].to_s == "finish" && @visit.currently_in_progress?
          finish_after_update
          return
        end

        # Stay on the visit workspace after a Save (changes / draft / vitals)
        # so the clinician sees their saved edit in context instead of being
        # bounced to the calendar. Cancel is the deliberate "leave" path
        # (it goes to the calendar); create still lands on the calendar since
        # scheduling a new visit naturally returns there.
        respond_to do |format|
          format.html { redirect_to edit_visit_path(@visit), status: :see_other, notice: "Visit updated." }
          format.json { head :ok }
        end
      else
        @clinicians = agency_clinicians
        @patients   = Patient.order(:mrn)
        respond_to do |format|
          format.html do
            flash.now[:alert] = @visit.errors.full_messages.to_sentence
            render :edit, status: :unprocessable_entity
          end
          format.json { render json: { errors: @visit.errors.full_messages }, status: :unprocessable_entity }
        end
      end
    end
  end

  # Shared with the standalone POST /visits/:id/finish endpoint.
  # Encapsulates the polish + extractor + MD routing logic so both
  # the new in-form Finish submit and any external callers share
  # one code path.
  def finish_after_update
    @visit.reload  # pick up just-saved narrative
    @visit.update!(ended_at: Time.current)
    flash[:notice] = "Visit completed. Thank you."

    # Polish runs on every visit type (not just admissions) so the
    # raw speaker-tagged transcript ("[Pascal:] Hello. How are you?
    # [Maria:] my back hurts") becomes a clean clinical chart entry
    # ("Patient reports back pain on greeting...") regardless of
    # whether an eval gets generated downstream. The raw transcript
    # is preserved in narrative_raw for survey verification.
    if @visit.narrative.to_s.strip.present? && @visit.narrative_raw.blank?
      raw = @visit.narrative.to_s
      @visit.update!(narrative_raw: raw)
      if (polish = HosalivioBrain.polish_narrative(raw))
        @visit.update!(narrative: polish["polished"])
        AgentEvent.create!(
          agency:      @visit.agency,
          agent_id:    "hosalivio_brain",
          action:      "polish_narrative",
          subject:     @visit,
          happened_at: Time.current,
          change_set:  { source: polish["source"], chars_in: raw.length, chars_out: polish["polished"].length }
        )
      end
    end

    # Care-team handoff summary (1-3 lines) from the polished note, shown on
    # the Team tab. Best-effort; a miss here never blocks finishing the visit.
    if @visit.team_summary.blank? && @visit.narrative.to_s.strip.present?
      if (sum = HosalivioBrain.summarize_for_team(narrative: @visit.narrative))
        @visit.update!(team_summary: sum["summary"])
      end
    end

    # Guarantee the eval exists for an admission visit before we extract into
    # it — otherwise an RN who finished without going through #begin would have
    # no linked eval and "Route to MD" would fail.
    if @visit.visit_type_admission? && (eval_rec = ensure_pre_admit_eval_for(@visit))
      result = PreAdmitNarrativeExtractor.call(
        narrative:     narrative_for_eval(@visit),
        existing_json: eval_rec.raw_json,
        visit:         @visit,
        patient:       @visit.patient
      )
      eval_rec.update!(raw_json: result.json)
      # Intake suggestions are staged in the post-record step
      # (prepare_recorded_admission_visit), not here — see that method.
      # MD routing is now an explicit second step (Route to MD button
      # on the visit edit page). Lets the RN review the polished
      # narrative + extracted eval JSON before shipping it to the
      # MD's queue. notify_md_for_certification fires from
      # VisitsController#route_to_md when the RN signs off.
      flash[:notice] = "Visit completed. Review the chart, then tap Route to MD when ready."
    end

    redirect_to edit_visit_path(@visit), status: :see_other
  end

  # POST /visits/:id/apply_intake_suggestions — RN accepts some/all of the
  # intake fields the admission narrative surfaced. Writes the accepted values
  # into the patient (blanks-only, defensively re-checked), then clears the
  # staging blob. params[:fields] is the list of accepted field keys.
  def apply_intake_suggestions
    ActsAsTenant.with_tenant(current_user.agency) do
      staged   = @visit.suggested_intake
      accepted = Array(params[:fields]).map(&:to_s) & staged.keys
      patient  = @visit.patient
      applied  = []
      intake_updates = {}

      accepted.each do |key|
        value = staged[key].to_s.strip
        next if value.blank?
        if Patient::INTAKE_KEYS.include?(key)
          next if patient.intake[key].present?          # blanks-only, re-checked
          intake_updates[key] = value
          applied << key
        elsif INTAKE_PATIENT_COLUMNS.include?(key)
          next unless column_blank?(patient, key)        # blanks-only, re-checked
          patient.public_send("#{key}=", value)
          applied << key
        end
      end

      patient.intake = patient.intake.merge(intake_updates) if intake_updates.any?
      patient.save! if applied.any?
      @visit.update!(suggested_intake: nil)

      if applied.any?
        AgentEvent.create!(
          agency: @visit.agency, agent_id: "hosalivio_brain", action: "apply_intake",
          subject: @visit, happened_at: Time.current, change_set: { fields: applied }
        )
        flash[:notice] = "Added #{applied.size} field#{'s' if applied.size != 1} to #{patient.full_name}'s intake."
      else
        flash[:notice] = "No intake fields applied."
      end
    end
    redirect_to edit_visit_path(@visit), status: :see_other
  end

  # POST /visits/:id/dismiss_intake_suggestions — RN discards the staged intake
  # suggestions without applying any.
  def dismiss_intake_suggestions
    ActsAsTenant.with_tenant(current_user.agency) { @visit.update!(suggested_intake: nil) }
    redirect_to edit_visit_path(@visit), status: :see_other, notice: "Intake suggestions dismissed."
  end

  # POST /visits/:id/route_to_md — explicit step the RN takes after
  # reviewing the polished chart entry + extracted eval. Fires the
  # MD notification + handoff that used to happen automatically on
  # Finish. Idempotent: if the eval was already routed, just
  # acknowledges so a double-click doesn't double-page MDs.
  def route_to_md
    ActsAsTenant.with_tenant(current_user.agency) do
      unless @visit.visit_type_admission?
        redirect_to(edit_visit_path(@visit), status: :see_other, alert: "Only admission visits route to MD for certification.") and return
      end
      unless (eval_rec = @visit.pre_admit_eval)
        redirect_to(edit_visit_path(@visit), status: :see_other, alert: "No linked pre-admit eval to route.") and return
      end
      already = Notification.exists?(kind: "pre_admit_review_ready", linked: eval_rec)
      if already
        redirect_to(edit_visit_path(@visit), status: :see_other, notice: "Already routed to MD.") and return
      end

      ok, err = Signatures::Gate.call(user: current_user, params: params)
      unless ok
        redirect_to(edit_visit_path(@visit), status: :see_other, alert: err) and return
      end

      Signatures::Apply.call(
        signable: eval_rec,
        user:     current_user,
        request:  request,
        method:   "rn_route_to_md",
        intent:   params[:intent_text].to_s.presence ||
                  "I certify that I have reviewed this pre-admit evaluation and authorize routing it to the on-call MD for certification."
      )

      # Transition draft → final so the MD's certify gate
      # (status_final?) accepts this eval. Resolve any open MD
      # revision requests at the same time so the RN's banner
      # disappears once they re-route.
      if eval_rec.status_draft?
        eval_rec.update!(status: :final, finalized_at: Time.current)
      end
      eval_rec.revision_requests.open.each(&:mark_resolved!)

      notify_md_for_certification(eval_rec)
      flash[:notice] = "Signed and routed to MD for certification."
      redirect_to edit_visit_path(@visit), status: :see_other
    end
  end

  # POST /visits/:id/sign_note — RN sign-off for non-admission
  # visits. Admission visits flow through #route_to_md instead
  # (the eval is the signable there). Once signed, Visit#chart_locked?
  # flips true and the team-narrative inline edit + the server-side
  # narrative-strip both lock the medical record.
  def sign_note
    ActsAsTenant.with_tenant(current_user.agency) do
      unless @visit.completed_visit?
        redirect_to(edit_visit_path(@visit), status: :see_other, alert: "Finish the visit before signing.") and return
      end
      if @visit.signed_off_by_rn?
        redirect_to(edit_visit_path(@visit), status: :see_other, notice: "Already signed.") and return
      end

      ok, err = Signatures::Gate.call(user: current_user, params: params)
      unless ok
        redirect_to(edit_visit_path(@visit), status: :see_other, alert: err) and return
      end

      Signatures::Apply.call(
        signable: @visit,
        user:     current_user,
        request:  request,
        method:   "rn_visit_signoff",
        intent:   params[:intent_text].to_s.presence ||
                  "I, the signing clinician, attest that this visit note is accurate and complete to the best of my knowledge."
      )

      flash[:notice] = "Visit note signed."
      redirect_to edit_visit_path(@visit), status: :see_other
    end
  end

  def destroy
    # Two real callers of destroy:
    #   1. Calendar's "Remove from schedule" (typically a scheduler role
    #      cleaning up a future or unstarted slot)
    #   2. The "Discard draft" button on /visits/:id/edit (the assigned
    #      clinician throwing away a draft they didn't intend to keep)
    #
    # Once a visit is completed (ended_at set) it's part of the medical
    # record — destroy is refused; corrections go through a late-entry
    # note instead.
    if @visit.completed_visit?
      redirect_to(edit_visit_path(@visit), status: :see_other, alert: "Completed visits can't be deleted. File a late-entry correction instead.") and return
    end

    is_scheduler = (current_user.role_names & %w[admin don admissions]).any?
    # The assigned clinician may discard their own in-progress DRAFT (a recording
    # they started and don't want to keep), but a not-yet-started SCHEDULED slot
    # is admin's schedule — only a scheduler removes it from the calendar.
    assigned_can_discard = @visit.user_id == current_user.id && @visit.started_at.present?
    unless is_scheduler || assigned_can_discard
      redirect_to(dashboard_path, status: :see_other,
                  alert: "Only admissions can remove a scheduled visit.") and return
    end

    @visit.destroy
    if params[:from] == "edit"
      redirect_to dashboard_path, status: :see_other, notice: "Draft visit discarded."
    else
      redirect_to calendar_path(date: (@visit.scheduled_at || Time.current).to_date),
                  status: :see_other,
                  notice: "Visit removed from the schedule."
    end
  end

  # Pascal clicks "Start visit" on My Day → stamps started_at if not already
  # set, then drops him into the documentation form with dictation ready.
  # For admission visits, also auto-drafts a PreAdmitEval so the narrative
  # bridges straight into the structured assessment when he hits Sync.
  # POST /visits/start_now
  # One-tap "start a visit at the bedside RIGHT NOW" — creates the
  # Visit with sensible defaults (current user is the clinician,
  # scheduled_at + started_at = now, place_of_service = home,
  # visit_type = routine, discipline = user's clinical role) and
  # lands on the edit page in :recording state, ready for dictation.
  # Avoids making Pascal fill the 12-field 'Schedule visit' form
  # before he can document at the bedside.
  def start_now
    patient_id = params[:patient_id].to_s
    return redirect_to(dashboard_path, alert: "Pick a patient to start a visit.") if patient_id.blank?

    ActsAsTenant.with_tenant(current_user.agency) do
      patient = Patient.find_by(id: patient_id)
      return redirect_to(dashboard_path, alert: "Patient not found.") unless patient

      # Idempotent: if THIS clinician already has an in-progress visit
      # for this patient, take them straight to that visit's recording
      # page instead of spawning duplicates on accidental double-taps.
      existing = patient.visits.where(user_id: current_user.id)
                                .where.not(started_at: nil)
                                .where(ended_at: nil)
                                .order(started_at: :desc).first
      return redirect_to(record_visit_path(existing)) if existing

      role = (current_user.role_names & Visit.disciplines.keys).first || "rn"
      now  = Time.current

      # Visit type comes from the quick-actions dropdown (Admission vs
      # Routine). If absent (older clients, dashboard one-tap), fall back
      # to a smart default: admission for never-admitted patients, routine
      # otherwise. This avoids the silent "routine" trap where SOC visits
      # would never trigger the pre-admit eval extraction.
      requested        = params[:visit_type].to_s
      explicit_type    = %w[admission routine recert].include?(requested)
      has_prior_admit  = patient.visits.where(visit_type: :admission).where.not(ended_at: nil).exists?
      visit_type = if explicit_type
                     requested
      elsif has_prior_admit
                     "routine"
      else
                     "admission"
      end

      visit = Visit.create!(
        agency:             current_user.agency,
        patient:            patient,
        user:               current_user,
        created_by_user_id: current_user.id,
        discipline:         role,
        visit_type:         visit_type,
        scheduled_at:       now,
        started_at:         now,
        service_location:   "home",
        narrative:          "",
        agent_authored:     false
      )
      # Land on the full-screen recording page, not the cluttered
      # edit form. The recording page captures the narrative + audio
      # and redirects to edit when the RN taps Stop. When the RN
      # didn't pre-pick a type (one-button quick action), pass pick=1
      # so the post-consent panel asks before the mic stage opens.
      redirect_to record_visit_path(visit, (explicit_type ? {} : { pick: 1 }))
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to dashboard_path, alert: "Could not start visit: #{e.record.errors.full_messages.to_sentence}"
  end

  # GET /visits/:id/record
  # Full-screen recording screen — large waveform, timer, Stop button.
  # Web Speech API captures the transcript, MediaRecorder captures the
  # audio Blob, AnalyserNode drives the live waveform. On Stop the
  # client PATCHes /visits/:id with narrative + audio_note as multipart
  # and the server bounces the user to the edit page with vitals
  # auto-extracted.
  def record
    if @visit.completed_visit? || @visit.chart_locked?
      redirect_to edit_visit_path(@visit), status: :see_other
      return
    end

    # Auto-stamp started_at if the visit hasn't begun yet (catches the
    # case where the RN clicked Start Visit on a card that wasn't yet
    # in :recording state).
    if @visit.started_at.nil?
      ActsAsTenant.with_tenant(current_user.agency) do
        @visit.update!(started_at: Time.current, ended_at: nil)
      end
    end

    # Type picker shows after consent when the visit was created
    # ad-hoc without an explicit type (one-button "Start a visit"
    # path). Scheduled visits skip this entirely. Suggestion: SOC
    # for never-admitted patients, routine otherwise.
    @needs_type_picker = params[:pick].to_s == "1"
    @suggested_type    =
      if @visit.patient.visits.where(visit_type: :admission)
                              .where.not(ended_at: nil, id: @visit.id)
                              .exists?
        "routine"
      else
        "admission"
      end

    # A family member with a photo, to put a face on the "The family" /
    # "Patient and family" options in the interviewee picker. Prefer active.
    @interview_family = User.where(patient_id: @visit.patient_id, family_access: true)
                            .order(active: :desc, updated_at: :desc)
                            .detect(&:has_avatar?)
  end

  # POST /visits/:id/discard
  # Cancel link on the recording screen calls this. Destroys the
  # visit only if it's truly empty (no narrative typed, no audio
  # attached, no ended_at) so we don't accidentally throw away real
  # work. If the visit has any content we leave it alone and just
  # bounce to the dashboard so the RN can pick it back up later.
  def discard
    ActsAsTenant.with_tenant(current_user.agency) do
      empty = @visit.narrative.to_s.strip.empty? &&
              !@visit.audio_note.attached? &&
              @visit.ended_at.nil?

      # A visit booked by someone else (admin/admissions scheduled it and
      # assigned this RN) is a real appointment — discarding the recording must
      # NEVER delete it. Only a visit the RN started ad-hoc (created_by == self)
      # is safe to remove when empty. Booked appointments revert to "scheduled".
      booked_appointment = @visit.created_by_user_id.present? &&
                           @visit.created_by_user_id != current_user.id

      if booked_appointment
        if empty
          @visit.update!(started_at: nil, ended_at: nil)
          cleanup_empty_draft_eval(@visit)
          flash[:notice] = "Visit returned to your schedule." unless request.format.json? || beacon_request?
        else
          flash[:notice] = "Visit kept (had content). You can finish it from My Day." unless beacon_request?
        end
      elsif empty
        @visit.destroy!
        flash[:notice] = "Visit discarded." unless request.format.json? || beacon_request?
      else
        flash[:notice] = "Visit kept (had content). You can finish it from My Day." unless beacon_request?
      end
    end

    # sendBeacon hits us with no Accept header / blob body and we don't
    # need the redirect — return 204 No Content so the browser is happy.
    if beacon_request?
      head :no_content
    else
      redirect_to dashboard_path
    end
  end

  def begin
    ActsAsTenant.with_tenant(current_user.agency) do
      if @visit.started_at.nil?
        @visit.update!(started_at: Time.current, ended_at: nil)
        flash[:notice] = "Visit in progress. Clock started at #{Time.current.strftime('%-l:%M %p')}."
      end

      if @visit.visit_type_admission? && @visit.pre_admit_eval.nil? &&
         PreAdmitEval.where(patient_id: @visit.patient_id, status: [ :draft, :final ]).none?
        PreAdmitEval.create!(
          agency:            current_user.agency,
          patient:           @visit.patient,
          visit:             @visit,
          evaluator:         current_user,
          evaluator_name:    current_user.full_name,
          evaluator_license: current_user.license_number,
          evaluator_role:    (current_user.role_names.first || "rn"),
          status:            :draft,
          evaluated_at:      Time.current,
          raw_json:          { "pre_admit_eval" => {} }
        )
        flash[:notice] = "#{flash[:notice]} Admission draft created — dictate your head-to-toe, then tap Sync to Eval."
      end
    end
    redirect_to edit_visit_path(@visit)
  end

  # "Sync to Eval" — runs the narrative through PreAdmitNarrativeExtractor
  # and merges extracted fields into the linked (or freshly-created) draft.
  def sync_to_eval
    ActsAsTenant.with_tenant(current_user.agency) do
      eval_rec = @visit.pre_admit_eval
      eval_rec ||= PreAdmitEval.where(patient_id: @visit.patient_id, status: :draft).first
      unless eval_rec
        redirect_to edit_visit_path(@visit),
                    alert: "No admission eval linked to this visit. Only admission visits auto-create one on Start."
        return
      end

      result = PreAdmitNarrativeExtractor.call(
        narrative:     narrative_for_eval(@visit),
        existing_json: eval_rec.raw_json,
        visit:         @visit,
        patient:       @visit.patient
      )
      eval_rec.update!(raw_json: result.json)

      if result.fields_updated.any?
        flash[:notice] = "Synced #{result.fields_updated.size} field#{'s' if result.fields_updated.size != 1} to the pre-admit eval. Review and finalize before routing to MD."
      else
        flash[:alert] = "No extractable signals found in the narrative yet. Keep documenting and try again."
      end
      redirect_to edit_pre_admit_eval_path(eval_rec)
    end
  end

  # Finish button on the documentation form: stamps ended_at, then for
  # admission visits auto-runs the narrative extractor (no separate
  # 'Sync to Eval' click needed) and routes the structured JSON to
  # the agency's MDs for certification review.
  def finish
    ActsAsTenant.with_tenant(current_user.agency) do
      if @visit.currently_in_progress?
        @visit.update!(ended_at: Time.current)
        flash[:notice] = "Visit completed. Thank you."

        # Polish step (admission visits only — routine visits don't
        # feed the structured eval, so spending an LLM call on them
        # adds cost without benefit). Save the raw transcript first
        # so surveyors can verify nothing was added or dropped, then
        # replace `narrative` with the polished version that drives
        # the chart + downstream extraction.
        if @visit.narrative.to_s.strip.present? && @visit.narrative_raw.blank?
          raw     = @visit.narrative.to_s
          @visit.update!(narrative_raw: raw)
          if (polish = HosalivioBrain.polish_narrative(raw))
            @visit.update!(narrative: polish["polished"])
            AgentEvent.create!(
              agency:      @visit.agency,
              agent_id:    "hosalivio_brain",
              action:      "polish_narrative",
              subject:     @visit,
              happened_at: Time.current,
              change_set: {
                source:    polish["source"],
                chars_in:  raw.length,
                chars_out: polish["polished"].length
              }
            )
          else
            Rails.logger.warn("[VisitsController#finish] polish_narrative returned nil; keeping raw narrative as displayed")
          end
        end

        if @visit.visit_type_admission? && (eval_rec = ensure_pre_admit_eval_for(@visit))
          result = PreAdmitNarrativeExtractor.call(
            narrative:     narrative_for_eval(@visit),
            existing_json: eval_rec.raw_json,
            visit:         @visit,
            patient:       @visit.patient
          )
          eval_rec.update!(raw_json: result.json)

          notify_md_for_certification(eval_rec)
          flash[:notice] = "Visit completed. Pre-admit eval updated and routed to MD for certification."
        end
      end
    end
    redirect_to dashboard_path
  end

  # POST /visits/:id/regenerate_summary — (re)generate the care-team handoff
  # summary from the current narrative. Used by the "Regenerate" button on the
  # Team tab after the RN edits the note.
  def regenerate_summary
    if @visit.narrative.to_s.strip.blank?
      redirect_to(edit_visit_path(@visit), status: :see_other, alert: "Nothing to summarize yet.") and return
    end
    sum = HosalivioBrain.summarize_for_team(narrative: @visit.narrative)
    if sum
      @visit.update!(team_summary: sum["summary"])
      redirect_to edit_visit_path(@visit, tab: "team"), status: :see_other, notice: "Care-team summary updated."
    else
      redirect_to edit_visit_path(@visit, tab: "team"), status: :see_other, alert: "Couldn't generate a summary just now. Try again."
    end
  end

  private

  # Pings every MD at the agency that a fresh admission eval is ready
  # for certification, plus sends a quiet copy to the DON for quality
  # oversight (non-blocking). Each MD's bell badge increments and the
  # MD agent now has a structured pre_admit_eval JSON to read for the
  # certification decision. Idempotent on (user, eval): if an MD
  # already has a 'pre_admit_review_ready' Notification linked to
  # this eval, we do not duplicate it.
  def notify_md_for_certification(eval_rec)
    assigned_md = eval_rec.patient.assigned_md

    # Certification goes to the patient's ASSIGNED MD. If there isn't one
    # (or they're inactive), fall back to every MD so the eval still reaches
    # someone rather than orphaning. DONs always get an oversight copy.
    md_targets =
      if assigned_md&.active?
        [ assigned_md ]
      else
        User.joins(user_roles: :role)
            .where(agency: eval_rec.agency, active: true)
            .where(roles: { name: "md" }).to_a
      end
    don_targets = User.joins(user_roles: :role)
                      .where(agency: eval_rec.agency, active: true)
                      .where(roles: { name: "don" }).to_a

    (md_targets + don_targets).uniq.each do |target|
      next if Notification.exists?(user: target, kind: "pre_admit_review_ready", linked: eval_rec)
      role = target.role_names.include?("md") ? "MD" : "DON"
      title = role == "MD" ?
        "Pre-admit eval ready to certify: #{eval_rec.patient.full_name}" :
        "Quality copy: pre-admit eval submitted for #{eval_rec.patient.full_name}"
      Notification.create!(
        agency: eval_rec.agency,
        user:   target,
        kind:   "pre_admit_review_ready",
        title:  title,
        linked: eval_rec
      )
    end

    # Emit a handoff event so the MD agent has a chart entry to act on
    # (same shape AgentTriager#write_pre_admit_eval emits when the
    # status flips to :final). Idempotent at the change_set level.
    AgentEvent.create!(
      agency:           eval_rec.agency,
      agent_id:         current_user.role_names.include?("rn") ? "rn" : "admissions",
      agent_session_id: "rn-finish-#{SecureRandom.hex(4)}",
      action:           "handoff",
      subject:          eval_rec,
      change_set: {
        target_role:   "md",
        target_user_id: assigned_md&.id,
        intent:        "pre_admit_certification",
        urgency:       "urgent",
        eval_id:       eval_rec.id,
        patient_name:  eval_rec.patient.full_name,
        primary_icd10: eval_rec.raw_json.dig("pre_admit_eval", "diagnosis", "primary_terminal_diagnosis", "icd10"),
        source:        "rn_finish_visit"
      },
      happened_at: Time.current
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[VisitsController#finish] notify_md_for_certification failed: #{e.message}")
  end

  def prepare_recorded_admission_visit
    return unless @visit.visit_type_admission?
    return if @visit.narrative.to_s.strip.blank?

    preserve_and_polish_recorded_narrative
    eval_rec = ensure_pre_admit_eval_for(@visit)
    sync_visit_narrative_to_eval(eval_rec)
    # The same recording also surfaces intake fields — stage them here (once,
    # right after recording) so the eval and the intake suggestions are both
    # generated in this post-record step. Guarded so a manual re-load with the
    # just_recorded hint doesn't resurface already-reviewed suggestions.
    stage_intake_suggestions(@visit) if @visit.suggested_intake.blank?
  rescue => e
    Rails.logger.warn("[VisitsController#prepare_recorded_admission_visit] #{e.class}: #{e.message}")
  end

  def preserve_and_polish_recorded_narrative
    raw = @visit.narrative.to_s
    return if raw.blank?
    if @visit.narrative_raw.blank?
      raw = tag_recorded_transcript(raw)
      @visit.update!(narrative_raw: raw)
    elsif !@visit.narrative_raw.to_s.match?(/\[[^\]\n]+:\]/) && @visit.narrative_raw.to_s == raw
      raw = tag_recorded_transcript(raw)
      @visit.update!(narrative_raw: raw)
    elsif @visit.narrative_raw.to_s != raw
      return
    end

    polish = HosalivioBrain.polish_narrative(raw)
    return unless polish&.dig("polished").present?

    @visit.update!(narrative: polish["polished"])
    AgentEvent.create!(
      agency:      @visit.agency,
      agent_id:    "hosalivio_brain",
      action:      "polish_narrative",
      subject:     @visit,
      happened_at: Time.current,
      change_set:  { source: polish["source"], chars_in: raw.length, chars_out: polish["polished"].length }
    )
  end

  def tag_recorded_transcript(raw)
    return raw if raw.to_s.match?(/\[[^\]\n]+:\]/)

    family_names = User.where(patient_id: @visit.patient_id, family_access: true, active: true).pluck(:full_name)
    clinician_role = (@visit.user&.role_names&.first || "rn").to_s.upcase
    tagged = HosalivioBrain.tag_speaker_turns(
      raw,
      patient_name:    @visit.patient.full_name,
      clinician_label: clinician_role,
      family_names:    family_names
    )
    tagged&.dig("tagged").presence || raw
  end

  def ensure_pre_admit_eval_for(visit)
    return visit.pre_admit_eval if visit.pre_admit_eval

    unclaimed = PreAdmitEval.where(patient_id: visit.patient_id, visit_id: nil, status: :draft).order(:created_at).last
    if unclaimed
      unclaimed.update!(visit: visit)
      return unclaimed
    end

    PreAdmitEval.create!(
      agency:            visit.agency,
      patient:           visit.patient,
      visit:             visit,
      evaluator:         visit.user,
      evaluator_name:    visit.user&.full_name,
      evaluator_license: visit.user&.license_number,
      evaluator_role:    (visit.user&.role_names&.first || "rn"),
      status:            :draft,
      evaluated_at:      visit.started_at || Time.current,
      raw_json:          { "pre_admit_eval" => {} }
    )
  rescue ActiveRecord::RecordNotUnique
    # A concurrent edit (double-click, Turbo prefetch + load) already linked an
    # eval to this visit; the partial unique index on visit_id rejected the
    # duplicate. Return the winner instead of erroring.
    visit.reload.pre_admit_eval
  end

  # When reverting an empty booked visit, drop the blank draft eval that
  # "Begin" auto-created for an admission so the patient isn't left with a
  # stray empty eval. Only deletes it when nothing was filled in.
  def cleanup_empty_draft_eval(visit)
    eval_rec = visit.pre_admit_eval
    return unless eval_rec&.status_draft?
    section = eval_rec.raw_json.is_a?(Hash) ? eval_rec.raw_json["pre_admit_eval"] : nil
    filled  = section.is_a?(Hash) && section.values.any?(&:present?)
    eval_rec.destroy! unless filled
  rescue => e
    Rails.logger.warn("[VisitsController#cleanup_empty_draft_eval] #{e.class}: #{e.message}")
  end

  def sync_visit_narrative_to_eval(eval_rec)
    result = PreAdmitNarrativeExtractor.call(
      narrative:     narrative_for_eval(@visit),
      existing_json: eval_rec.raw_json,
      visit:         @visit,
      patient:       @visit.patient
    )
    eval_rec.update!(raw_json: result.json)
  end

  def narrative_for_eval(visit)
    [ visit.narrative, visit.narrative_raw ]
      .map { |text| text.to_s.strip }
      .reject(&:blank?)
      .uniq
      .join("\n\nRaw transcript:\n")
  end

  # Stage the intake fields the admission narrative surfaced for RN review.
  # Blanks-only (enforced by the extractor). Best-effort: a failure here never
  # blocks finishing the visit.
  def stage_intake_suggestions(visit)
    suggestions = Intake::NarrativeExtractor.call(
      narrative: narrative_for_eval(visit), patient: visit.patient
    )
    return if suggestions.blank?

    visit.update!(suggested_intake: suggestions)
    AgentEvent.create!(
      agency:      visit.agency,
      agent_id:    "hosalivio_brain",
      action:      "suggest_intake",
      subject:     visit,
      happened_at: Time.current,
      change_set:  { fields: suggestions.keys }
    )
  rescue => e
    Rails.logger.warn("[Intake::NarrativeExtractor] staging failed: #{e.class}: #{e.message}")
  end

  # Blanks-only check for a staged Patient *column*. code_status defaults to
  # full_code, so "blank" there means still on that default.
  def column_blank?(patient, key)
    key == "code_status" ? patient.code_status.to_s == "full_code" : patient.public_send(key).blank?
  end

  def set_visit
    ActsAsTenant.with_tenant(current_user.agency) do
      @visit = Visit.find(params[:id])
    end
    return if visit_accessible?(@visit)
    redirect_to dashboard_path, status: :see_other,
                alert: "That visit isn't assigned to you."
  end

  # A visit is the assigned clinician's workspace. Only that clinician, whoever
  # scheduled it, agency managers (admin/DON/admissions), and the reviewing
  # MD may open / record / edit / route it — so an unassigned clinician (e.g.
  # another RN) can't touch an admission that isn't theirs and corrupt its
  # audit trail or sign-off.
  VISIT_ACCESS_ROLES = %w[admin don admissions md].freeze
  def visit_accessible?(visit)
    return true if visit.user_id == current_user.id
    return true if visit.created_by_user_id == current_user.id
    (current_user.role_names & VISIT_ACCESS_ROLES).any?
  end

  # Mutating a visit (record / begin / finish / route-to-MD / sign / discard /
  # save edits / regenerate summary) is the assigned clinician's job; managers
  # may act for oversight. The reviewing MD can READ a visit for clinical
  # context (visit_accessible?) but must NOT write to it or sign the RN's
  # route-to-MD handoff — note md is absent from VISIT_WRITER_ROLES.
  VISIT_WRITER_ROLES = %w[admin don admissions].freeze
  def authorize_visit_writer!
    return if @visit.user_id == current_user.id
    return if @visit.created_by_user_id == current_user.id
    return if (current_user.role_names & VISIT_WRITER_ROLES).any?
    redirect_to dashboard_path, status: :see_other,
                alert: "That visit belongs to the assigned clinician."
  end

  # navigator.sendBeacon doesn't set an Accept header that smells like
  # an HTML page request. Detect by absence of common interactive
  # accept types so the discard action returns 204 instead of trying
  # to redirect.
  def beacon_request?
    accept = request.headers["Accept"].to_s
    accept.empty? || accept.include?("*/*") && !accept.include?("text/html")
  end

  # Scheduling a visit (assigning a patient + clinician + date via the new/create
  # form) is an admin / admissions / DON action. Performing clinicians start
  # their OWN visit through #start_now (self-assigned) and record the visits
  # already on their list — they never use the scheduler form.
  SCHEDULER_ROLES = %w[admin don admissions].freeze
  def authorize_visit_scheduler!
    return if (current_user.role_names & SCHEDULER_ROLES).any?
    redirect_to dashboard_path, status: :see_other,
                alert: "Only admin, DON, or admissions can schedule visits."
  end

  def redirect_family_users
    return unless current_user&.family_access?
    redirect_to(current_user.patient_id ? patient_path(current_user.patient_id) : welcome_path)
  end

  def visit_params
    params.require(:visit).permit(
      :patient_id, :user_id, :discipline, :visit_type,
      :scheduled_at, :ended_at,
      :service_location, :facility_name,
      :interviewee, :interviewee_label,
      :narrative, :pain_score, :billable, :visit_code,
      :audio_note, :transcript_segments,
      vitals: [ :bp, :temp, :pulse, :resp, :o2 ]
    )
  end

  def parse_time(raw) = (Time.zone.parse(raw.to_s) rescue nil)

  # HIPAA: log every time decrypted address/phone is surfaced in a detail view.
  # PaperTrail records the write side; this closes the loop on reads.
  def audit_phi_reveal(visit)
    return unless visit&.patient_id
    Rails.logger.info(
      "[PHI_REVEAL] user=#{current_user.id} (#{current_user.email}) " \
      "patient=#{visit.patient_id} visit=#{visit.id} " \
      "agency=#{visit.agency_id} at=#{Time.current.iso8601}"
    )
  end

  def default_slot
    # Next open quarter-hour, at least one hour from now.
    base = 1.hour.from_now
    Time.zone.local(base.year, base.month, base.day, base.hour, (base.min / 15) * 15, 0)
  end

  CLINICAL_ROLES = %w[rn md don sw chaplain aide social_worker].freeze
  def agency_clinicians
    scope = User.joins(user_roles: :role)
                .where(agency: current_user.agency, active: true)
                .where(roles: { name: CLINICAL_ROLES })
                .includes(:branch)
                .distinct
                .order(:full_name)
    # Fallback for partner agencies with only a coordinator seeded.
    scope.any? ? scope : User.where(id: current_user.id).includes(:branch)
  end
end
