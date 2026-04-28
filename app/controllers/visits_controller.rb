class VisitsController < ApplicationController
  before_action :authenticate_user!
  before_action :redirect_family_users
  before_action :set_visit, only: [:show, :edit, :update, :destroy, :begin, :finish, :record, :discard]

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
      @visit = Visit.new(visit_params.merge(agency: current_user.agency, agent_authored: false))
      if @visit.save
        redirect_to calendar_path(date: (@visit.scheduled_at || Time.current).to_date),
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
    end
    render :edit, layout: false if request.headers["Turbo-Frame"] || params[:modal]
  end

  def update
    ActsAsTenant.with_tenant(current_user.agency) do
      if @visit.update(visit_params.merge(agent_authored: false))
        redirect_to calendar_path(date: (@visit.scheduled_at || Time.current).to_date),
                    notice: "Visit updated."
      else
        @clinicians = agency_clinicians
        @patients   = Patient.order(:mrn)
        flash.now[:alert] = @visit.errors.full_messages.to_sentence
        render :edit, status: :unprocessable_entity
      end
    end
  end

  def destroy
    @visit.destroy
    redirect_to calendar_path(date: (@visit.scheduled_at || Time.current).to_date),
                notice: "Visit removed from the schedule."
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
      visit = Visit.create!(
        agency:           current_user.agency,
        patient:          patient,
        user:             current_user,
        discipline:       role,
        visit_type:       "routine",
        scheduled_at:     now,
        started_at:       now,
        service_location: "home",
        narrative:        "",
        agent_authored:   false
      )
      # Land on the full-screen recording page, not the cluttered
      # edit form. The recording page captures the narrative + audio
      # and redirects to edit when the RN taps Stop.
      redirect_to record_visit_path(visit)
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
    # Auto-stamp started_at if the visit hasn't begun yet (catches the
    # case where the RN clicked Start Visit on a card that wasn't yet
    # in :recording state).
    if @visit.started_at.nil?
      ActsAsTenant.with_tenant(current_user.agency) do
        @visit.update!(started_at: Time.current)
      end
    end
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
      if empty
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
        @visit.update!(started_at: Time.current)
        flash[:notice] = "Visit in progress. Clock started at #{Time.current.strftime('%-l:%M %p')}."
      end

      if @visit.visit_type_admission? && @visit.pre_admit_eval.nil? &&
         PreAdmitEval.where(patient_id: @visit.patient_id, status: [:draft, :final]).none?
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
        narrative:     @visit.narrative.to_s,
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
      if @visit.started_at && @visit.ended_at.nil?
        @visit.update!(ended_at: Time.current)
        flash[:notice] = "Visit completed. Thank you."

        if @visit.visit_type_admission? && (eval_rec = @visit.pre_admit_eval)
          result = PreAdmitNarrativeExtractor.call(
            narrative:     @visit.narrative.to_s,
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

  private

  # Pings every MD at the agency that a fresh admission eval is ready
  # for certification, plus sends a quiet copy to the DON for quality
  # oversight (non-blocking). Each MD's bell badge increments and the
  # MD agent now has a structured pre_admit_eval JSON to read for the
  # certification decision. Idempotent on (user, eval): if an MD
  # already has a 'pre_admit_review_ready' Notification linked to
  # this eval, we do not duplicate it.
  def notify_md_for_certification(eval_rec)
    targets = User.joins(user_roles: :role)
                  .where(agency: eval_rec.agency, active: true)
                  .where(roles: { name: %w[md don] })
    targets.find_each do |target|
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

  def set_visit
    ActsAsTenant.with_tenant(current_user.agency) do
      @visit = Visit.find(params[:id])
    end
  end

  # navigator.sendBeacon doesn't set an Accept header that smells like
  # an HTML page request. Detect by absence of common interactive
  # accept types so the discard action returns 204 instead of trying
  # to redirect.
  def beacon_request?
    accept = request.headers["Accept"].to_s
    accept.empty? || accept.include?("*/*") && !accept.include?("text/html")
  end

  def redirect_family_users
    return unless current_user&.family_access?
    redirect_to(current_user.patient_id ? patient_path(current_user.patient_id) : welcome_path)
  end

  def visit_params
    params.require(:visit).permit(
      :patient_id, :user_id, :discipline, :visit_type,
      :scheduled_at, :started_at, :ended_at,
      :service_location, :facility_name,
      :narrative, :pain_score, :billable, :visit_code,
      :audio_note,
      vitals: [:bp, :temp, :pulse, :resp, :o2]
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
