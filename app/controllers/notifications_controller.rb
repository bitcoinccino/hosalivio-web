class NotificationsController < ApplicationController
  before_action :authenticate_user!

  # GET /notifications — full inbox
  def index
    ActsAsTenant.with_tenant(current_user.agency) do
      @notifications = Notification.where(user: current_user).newest_first.limit(100)
    end
  end

  # POST /notifications/:id/mark_read
  def mark_read
    ActsAsTenant.with_tenant(current_user.agency) do
      n = Notification.find_by(id: params[:id], user_id: current_user.id)
      n&.mark_read!
    end
    Notification.broadcast_badge(agency_id: current_user.agency_id, user_id: current_user.id)
    redirect_back fallback_location: notifications_path
  end

  # POST /notifications/mark_all_read
  def mark_all_read
    ActsAsTenant.with_tenant(current_user.agency) do
      Notification.where(user: current_user, read_at: nil).update_all(read_at: Time.current)
    end
    Notification.broadcast_badge(agency_id: current_user.agency_id, user_id: current_user.id)
    redirect_back fallback_location: notifications_path
  end
end
