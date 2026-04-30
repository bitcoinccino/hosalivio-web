# Inline acknowledge button on the My Day handoffs card POSTs here.
# Stamps the AgentEvent acknowledged + posts a clinician_only ack
# note in the patient chat ("Pascal acknowledged the pain crisis at
# 11:13 AM") so other staff see who's on it. The dashboard re-renders
# the handoffs card via the existing AgentEvent broadcast hook so
# the row drops off the queue without a page refresh.
class HandoffAcknowledgmentsController < ApplicationController
  before_action :authenticate_user!

  def create
    ev = AgentEvent.unscoped.find(params[:agent_event_id])
    head(:forbidden) and return if ev.agency_id != current_user.agency_id

    role_target = ev.change_set.is_a?(Hash) ? ev.change_set["target_role"].to_s : ""
    unless current_user.role_names.include?(role_target)
      head(:forbidden) and return
    end

    if ev.acknowledged?
      flash[:alert] = "Already acknowledged."
      redirect_to(dashboard_path) and return
    end

    ev.acknowledge!(current_user)

    # Post a clinician_only ack note to the patient chat so other
    # staff see this is being handled. Skip silently if the ev
    # subject doesn't resolve to a patient (rare).
    patient = ev.subject.is_a?(Patient) ? ev.subject : ev.subject.try(:patient)
    if patient
      Note.create!(
        agency:         patient.agency,
        patient:        patient,
        author_user:    current_user,
        author_role:    current_user.role_names.first || "rn",
        body:           "[HOSALIVIO_ACK] #{current_user.full_name.split.first} acknowledged the #{(ev.change_set["intent"] || "handoff").to_s.tr('_', ' ')} alert.",
        urgency:        "normal",
        source:         "system",
        clinician_only: true
      )
    end

    # Re-broadcast handoffs card for self (and the rest of the role's
    # users) so the acknowledged row drops off everywhere.
    User.unscoped
        .where(agency_id: current_user.agency_id, active: true, family_access: false)
        .joins(user_roles: :role)
        .where(roles: { name: role_target })
        .find_each do |target|
      data = DashboardData.for(target)
      Turbo::StreamsChannel.broadcast_replace_to(
        "dashboard:user:#{target.id}",
        target:  "dashboard-handoffs-#{target.id}",
        partial: "dashboards/handoffs_card",
        locals:  { pending_handoffs: data.pending_handoffs, viewer_user_id: target.id }
      )
    end

    respond_to do |format|
      format.turbo_stream { head :ok }
      format.html         { redirect_to dashboard_path, notice: "Acknowledged." }
    end
  end
end
