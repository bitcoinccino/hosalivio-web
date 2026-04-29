# Per-user My Day live channel. Each clinician streams from
# `dashboard:user:<id>`; the after_commit hooks on AgentEvent,
# MedicationLog, and Visit broadcast turbo_stream.replace payloads
# targeting the matching turbo-frame on the dashboard so the right
# card refreshes itself.
#
# Auth gate: a user can only subscribe to their OWN stream. Without
# this any signed-in user could subscribe to another user's queue.
class DashboardChannel < ApplicationCable::Channel
  def subscribed
    user_id = params[:user_id].to_s
    reject and return if user_id.blank?
    reject and return unless current_user_or_reject(user_id)
    stream_from "dashboard:user:#{user_id}"
  end

  private

  def current_user_or_reject(user_id)
    cu = connection.try(:current_user)
    cu && cu.id.to_s == user_id
  end
end
