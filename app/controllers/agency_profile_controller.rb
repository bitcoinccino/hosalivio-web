# Agency profile editor: a single form covering everything captured
# during the partner-signup wizard plus the full mailing address.
# Admin / DON / admissions can edit; everyone else gets redirected.

class AgencyProfileController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_admin!

  PRIVILEGED_ROLES = %w[admin don admissions ceo].freeze

  PERMITTED = %i[
    name dba_name slug
    npi medicare_provider_number
    accreditation_body administrator_name
    address_line1 address_line2 city state zip
    phone
    mac_region emr_system pharmacy_partner dme_partner
    after_hours_instructions
  ].freeze

  def edit
    @agency = current_user.agency
  end

  def update
    @agency = current_user.agency
    if @agency.update(profile_params)
      redirect_to edit_agency_profile_path, notice: "Agency profile saved."
    else
      flash.now[:alert] = @agency.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def authorize_admin!
    return if (current_user.role_names & PRIVILEGED_ROLES).any?
    redirect_to dashboard_path, alert: "Only admins can edit the agency profile."
  end

  def profile_params
    params.require(:agency).permit(*PERMITTED).tap do |p|
      # Empty strings on enum fields persist as 0 (the first enum value)
      # rather than NULL — coerce to nil so 'Unselected' stays unselected.
      %i[accreditation_body mac_region emr_system pharmacy_partner dme_partner].each do |k|
        p[k] = nil if p[k].blank?
      end
      p[:slug] = p[:slug].to_s.strip.upcase if p.key?(:slug)
      p[:state] = p[:state].to_s.strip.upcase if p.key?(:state)
    end
  end
end
