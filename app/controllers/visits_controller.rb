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
  def begin
    ActsAsTenant.with_tenant(current_user.agency) do
      if @visit.started_at.nil?
        @visit.update!(started_at: Time.current)
        flash[:notice] = "Visit started at #{Time.current.strftime('%-l:%M %p')}. Dictate your narrative below."
      else
        flash[:notice] = "Already in progress — pick up where you left off."
      end
    end
    redirect_to edit_visit_path(@visit)
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
