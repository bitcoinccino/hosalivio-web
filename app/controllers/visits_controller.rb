class VisitsController < ApplicationController
  before_action :authenticate_user!
  before_action :redirect_family_users
  before_action :set_visit, only: [:show, :edit, :update, :destroy, :begin, :finish]

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
      redirect_to edit_visit_path(visit)
    end
  rescue ActiveRecord::RecordInvalid => e
    redirect_to dashboard_path, alert: "Could not start visit: #{e.record.errors.full_messages.to_sentence}"
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

  # Finish button on the documentation form: stamps ended_at and returns to the
  # calendar so he can move on to the next visit.
  def finish
    ActsAsTenant.with_tenant(current_user.agency) do
      if @visit.started_at && @visit.ended_at.nil?
        @visit.update!(ended_at: Time.current)
        flash[:notice] = "Visit completed. Thank you."
      end
    end
    redirect_to dashboard_path
  end

  private

  def set_visit
    ActsAsTenant.with_tenant(current_user.agency) do
      @visit = Visit.find(params[:id])
    end
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
