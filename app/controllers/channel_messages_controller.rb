class ChannelMessagesController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_staff!

  def create
    ActsAsTenant.with_tenant(current_user.agency) do
      channel = Channel.find_by!(slug: params[:channel_slug])
      body    = params[:body].to_s.strip

      # Posts made from the Mission Stage composer come back to the dashboard
      # (with a confirmation), rather than yanking the manager into the channel.
      from_dashboard = params[:return_to] == "dashboard"
      back           = from_dashboard ? dashboard_path : channel_path(channel)

      unless channel.postable_by?(current_user)
        return redirect_to back, status: :see_other,
                           alert: "You can read ##{channel.slug} but only its team can post."
      end

      if body.present?
        parent = params[:parent_id].present? ? channel.channel_messages.roots.find_by(id: params[:parent_id]) : nil
        channel.channel_messages.create!(agency: current_user.agency, user: current_user, body: body, parent: parent)
      end
      redirect_to back, status: :see_other,
                  notice: (from_dashboard ? "Posted to ##{channel.slug}." : nil)
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
