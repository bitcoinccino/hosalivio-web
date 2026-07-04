# Team channels — agency-wide, non-patient team chat (see Channel). Staff only;
# family users are redirected. The default channels are provisioned lazily so
# every agency always has #General + #Admission.
class ChannelsController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_staff!

  def index
    load_channels
    @channel = default_channel
    load_messages
  end

  def show
    load_channels
    @channel = @channels.find { |c| c.slug == params[:slug] } || default_channel
    load_messages
    render :index
  end

  private

  def load_channels
    ActsAsTenant.with_tenant(current_user.agency) do
      Channel.ensure_defaults_for(current_user.agency)
      @channels = Channel.ordered.to_a
    end
  end

  # #General is the default landing channel.
  def default_channel
    @channels.find { |c| c.slug == "general" } || @channels.first
  end

  def load_messages
    ActsAsTenant.with_tenant(current_user.agency) do
      @messages = @channel.channel_messages.includes(:user).last(100)
      @can_post = @channel.postable_by?(current_user)
    end
  end

  def authorize_staff!
    return unless current_user.family_access?
    redirect_to dashboard_path, status: :see_other, alert: "Team chat is for staff."
  end
end
