class ProfilesController < ApplicationController
  before_action :authenticate_user!

  # Self-serve profile editing. Admin-gated fields (license, caseload,
  # on_call) are read-only here — only the DON can change those via
  # /team_members to preserve oversight.
  def edit
    @user = current_user
  end

  def update
    @user = current_user
    if @user.update(profile_params)
      flash[:notice] = "Profile updated."
      redirect_to edit_profile_path
    else
      flash.now[:alert] = @user.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  def remove_avatar
    current_user.avatar.purge if current_user.avatar.attached?
    redirect_to edit_profile_path, notice: "Profile photo removed."
  end

  private

  # Self-editable fields. License number, expiration, caseload cap, and
  # on_call toggle are intentionally excluded — those belong to the DON.
  def profile_params
    base = %i[full_name email phone_number timezone avatar]
    clinical_role = (current_user.role_names & %w[rn md don admissions sw social_worker chaplain aide insurance billing dme pharmacy]).any?
    base += %i[npi service_zips] if clinical_role
    params.require(:user).permit(*base)
  end
end
