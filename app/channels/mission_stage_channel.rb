class MissionStageChannel < ApplicationCable::Channel
  def subscribed
    agency_id = params[:agency_id]
    reject and return if agency_id.blank?
    stream_from "mission_stage:#{agency_id}"
  end
end
