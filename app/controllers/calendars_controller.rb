class CalendarsController < ApplicationController
  before_action :authenticate_user!
  before_action :redirect_family_users

  # GET /calendar(?date=YYYY-MM-DD)
  def show
    @agency = current_user.agency || Agency.first
    return if @agency.nil?

    @week_start = parse_week_start(params[:date])
    @week_end   = @week_start + 6.days
    @days       = (0..6).map { |i| @week_start + i.days }

    ActsAsTenant.with_tenant(@agency) do
      # Managers (admin / admissions / DON) see the whole team grid for
      # scheduling oversight; a performing clinician (RN, MD, etc.) sees only
      # their own column — their schedule, not the whole team's.
      manager     = (current_user.role_names & %w[admin don admissions ceo]).any?
      @clinicians = manager ? agency_clinicians(@agency) : [ current_user ]
      @visits     = Visit
        .where(user_id: @clinicians.map(&:id))
        .where("COALESCE(scheduled_at, started_at) BETWEEN ? AND ?",
               @week_start.beginning_of_day, @week_end.end_of_day)
        .order(Arel.sql("COALESCE(scheduled_at, started_at) ASC"))
        .includes(:patient, :user)
        .to_a
    end

    # Build { [user_id, date] => [visits, …] } so the view can render each cell in O(1)
    @cells = Hash.new { |h, k| h[k] = [] }
    @visits.each do |v|
      day = (v.scheduled_at || v.started_at).to_date
      @cells[[ v.user_id, day ]] << v
    end
  end

  private

  def redirect_family_users
    return unless current_user&.family_access?
    redirect_to(current_user.patient_id ? patient_path(current_user.patient_id) : welcome_path)
  end

  def parse_week_start(raw)
    d = (Date.parse(raw.to_s) rescue Date.current)
    d.beginning_of_week(:monday)
  end

  # Clinicians are agency users holding any of the bedside-adjacent roles.
  CLINICAL_ROLES = %w[rn md don sw chaplain aide social_worker].freeze
  def agency_clinicians(agency)
    User.joins(user_roles: :role)
        .where(agency: agency, active: true)
        .where(roles: { name: CLINICAL_ROLES })
        .distinct
        .order(:full_name)
  end
end
