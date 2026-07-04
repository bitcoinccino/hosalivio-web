class ChannelMessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_staff!

  def create
    ActsAsTenant.with_tenant(current_user.agency) do
      channel = Channel.find_by!(slug: params[:channel_slug])
      body    = params[:body].to_s.strip

      unless channel.postable_by?(current_user)
        return redirect_to channel_path(channel), status: :see_other,
                           alert: "You can read ##{channel.slug} but only its team can post."
      end

      if body.present?
        channel.channel_messages.create!(agency: current_user.agency, user: current_user, body: body)
      end
      redirect_to channel_path(channel), status: :see_other
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to channels_path, status: :see_other, alert: "Channel not found."
  end

  private

  def authorize_staff!
    return unless current_user.family_access?
    redirect_to dashboard_path, status: :see_other, alert: "Team chat is for staff."
  end
end
