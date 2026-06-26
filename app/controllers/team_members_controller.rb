class TeamMembersController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_team_manager!
  before_action :set_member, only: [ :edit, :update, :destroy, :reactivate ]

  CLINICAL_ROLES = %w[rn lpn md don sw social_worker chaplain aide admissions insurance billing dme pharmacy].freeze
  DEFAULT_PASSWORD = "hello123".freeze

  def index
    ActsAsTenant.with_tenant(current_user.agency) do
      @branches = Branch.where(agency: current_user.agency).order(:name)
      scope = User.where(agency: current_user.agency)
                  .where(family_access: [ false, nil ])
                  .includes(:roles, :branch)
                  .order(active: :desc, full_name: :asc)
      @members_by_branch = scope.group_by(&:branch_id)
      @expiring = scope.where(active: true)
                       .where(license_expires_on: ..(Date.current + 60.days))
                       .order(:license_expires_on)
    end
  end

  def new
    @member = User.new(
      timezone:  current_user.timezone.presence || "America/New_York",
      branch_id: params[:branch_id].presence || current_user.branch_id
    )
    @role_name = params[:role].presence_in(CLINICAL_ROLES) || "rn"
    @branches  = Branch.where(agency: current_user.agency, active: true).order(:name)
  end

  def create
    role_name = params.dig(:user, :role_name).to_s
    unless CLINICAL_ROLES.include?(role_name)
      redirect_to new_team_member_path, status: :see_other, alert: "Pick a valid role." and return
    end

    ActsAsTenant.with_tenant(current_user.agency) do
      @member = User.new(member_params.merge(
        agency: current_user.agency,
        active: true,
        family_access: false,
        password: DEFAULT_PASSWORD,
        password_confirmation: DEFAULT_PASSWORD
      ))

      if @member.save
        role = Role.find_or_create_by!(name: role_name)
        @member.user_roles.create!(role: role)
        redirect_to team_members_path,
                    status: :see_other,
                    notice: "Added #{@member.full_name} (#{role_name}). Temporary password: #{DEFAULT_PASSWORD}"
      else
        @role_name = role_name
        @branches  = Branch.where(agency: current_user.agency, active: true).order(:name)
        flash.now[:alert] = @member.errors.full_messages.to_sentence
        render :new, status: :unprocessable_entity
      end
    end
  end

  def edit
    @branches = Branch.where(agency: current_user.agency, active: true).order(:name)
  end

  def update
    if @member.update(member_params)
      redirect_to team_members_path, status: :see_other, notice: "Updated #{@member.full_name}."
    else
      @branches = Branch.where(agency: current_user.agency, active: true).order(:name)
      flash.now[:alert] = @member.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @member == current_user
      redirect_to team_members_path, status: :see_other, alert: "You can't deactivate yourself." and return
    end
    @member.update!(active: false)
    redirect_to team_members_path, status: :see_other, notice: "#{@member.full_name} deactivated."
  end

  def reactivate
    @member.update!(active: true)
    redirect_to team_members_path, status: :see_other, notice: "#{@member.full_name} reactivated."
  end

  private

  def set_member
    ActsAsTenant.with_tenant(current_user.agency) do
      @member = User.where(agency: current_user.agency).find(params[:id])
    end
  end

  MANAGER_ROLES = %w[admin don admissions].freeze
  def authorize_team_manager!
    return if (current_user.role_names & MANAGER_ROLES).any?
    redirect_to dashboard_path, alert: "Only coordinators, DONs, or admins can manage the team."
  end

  def member_params
    params.require(:user).permit(
      :full_name, :friendly_name, :email, :timezone, :branch_id,
      :phone_number, :npi, :license_number, :license_expires_on,
      :employment_type, :max_caseload, :on_call,
      :service_zips
    )
  end
end
