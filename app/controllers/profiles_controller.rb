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
    permitted = params.require(:user).permit(
      *base,
      notification_channels: [
        :_destroy,
        { telegram:    [:enabled, :chat_id] },
        { whatsapp:    [:enabled, :phone] },
        { sms:         [:enabled, :phone] },
        { email:       [:enabled] },
        { quiet_hours: [:start, :end, :timezone] }
      ]
    )

    # Coerce form values into the canonical User#notification_channels shape.
    if permitted.key?(:notification_channels)
      raw = permitted[:notification_channels].to_h
      permitted[:notification_channels] = User::CHANNEL_KEYS.each_with_object({}) do |k, acc|
        sub = raw[k.to_s] || raw[k.to_sym] || {}
        acc[k] = {
          "enabled" => ActiveModel::Type::Boolean.new.cast(sub["enabled"] || sub[:enabled]) || false,
          "chat_id" => sub["chat_id"].to_s.presence,
          "phone"   => sub["phone"].to_s.presence
        }.compact
      end.merge("quiet_hours" => coerce_quiet_hours(raw["quiet_hours"] || raw[:quiet_hours]))
    end
    permitted
  end

  def coerce_quiet_hours(qh)
    return {} unless qh.is_a?(ActionController::Parameters) || qh.is_a?(Hash)
    h = qh.to_h
    {
      "start"    => h["start"].to_s.presence,
      "end"      => h["end"].to_s.presence,
      "timezone" => h["timezone"].to_s.presence || current_user.timezone
    }.compact
  end
end
