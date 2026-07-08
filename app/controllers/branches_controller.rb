class BranchesController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_branch_manager!
  before_action :set_branch, only: [ :edit, :update, :destroy ]

  MANAGER_ROLES = %w[admin admissions].freeze

  def index
    ActsAsTenant.with_tenant(current_user.agency) do
      @branches = Branch.where(agency: current_user.agency).order(:name).includes(:manager)
    end
  end

  def new
    @branch = Branch.new(agency: current_user.agency, active: true)
  end

  def create
    ActsAsTenant.with_tenant(current_user.agency) do
      @branch = Branch.new(branch_params.merge(agency: current_user.agency))
      if @branch.save
        redirect_to branches_path, notice: "Branch '#{@branch.name}' created."
      else
        flash.now[:alert] = @branch.errors.full_messages.to_sentence
        render :new, status: :unprocessable_entity
      end
    end
  end

  def edit; end

  def update
    if @branch.update(branch_params)
      redirect_to branches_path, notice: "Branch updated."
    else
      flash.now[:alert] = @branch.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    if @branch.users.any? || @branch.patients.any?
      redirect_to branches_path, alert: "Can't delete '#{@branch.name}' while users or patients are assigned. Move them first." and return
    end
    @branch.destroy
    redirect_to branches_path, notice: "Branch removed."
  end

  private

  def set_branch
    ActsAsTenant.with_tenant(current_user.agency) do
      @branch = Branch.where(agency: current_user.agency).find(params[:id])
    end
  end

  def branch_params
    params.require(:branch).permit(
      :name, :address_line1, :address_line2, :city, :state, :zip,
      :phone, :manager_id, :active,
      :npi, :ccn, :ein, :state_license_number,
      :timezone, :triage_email, :after_hours_phone, :branch_type,
      :medical_director_id, :director_of_nursing_id, :clinical_supervisor_id,
      service_area_zips: [], service_area_counties: [], levels_of_care: []
    )
  end

  def authorize_branch_manager!
    return if (current_user.role_names & MANAGER_ROLES).any?
    redirect_to dashboard_path, alert: "Only coordinators, DONs, or admins can manage branches."
  end
end
