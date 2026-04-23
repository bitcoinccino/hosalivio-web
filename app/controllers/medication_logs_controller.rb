class MedicationLogsController < ApplicationController
  before_action :authenticate_user!

  # One-click "Mark as given" from the My Day overdue-meds card.
  # Creates a MedicationLog stamped with the current clinician + now.
  def create
    order = MedicationOrder.find(params[:medication_order_id])
    ActsAsTenant.with_tenant(order.agency) do
      MedicationLog.create!(
        agency:           order.agency,
        medication_order: order,
        administered_by:  current_user,
        administered_at:  Time.current,
        dose_given:       order.dose.presence || "as ordered",
        source:           :home_supply
      )
    end
    flash[:notice] = "Logged #{order.drug_name} #{order.dose} for #{order.patient.full_name}."
    redirect_back(fallback_location: dashboard_path)
  end

  # "Escalate to MD" — fires a handoff AgentEvent for the patient's MD role.
  def escalate
    order = MedicationOrder.find(params[:medication_order_id])
    ActsAsTenant.with_tenant(order.agency) do
      Current.agency           = order.agency
      Current.agent_id         = current_user.role_names.first
      Current.agent_session_id = "escalate-#{SecureRandom.hex(3)}"

      AgentEvent.create!(
        agency:           order.agency,
        agent_id:         Current.agent_id,
        agent_session_id: Current.agent_session_id,
        action:           "handoff",
        subject:          order.patient,
        change_set: {
          target_role:   "md",
          intent:        "med_review_overdue",
          urgency:       "urgent",
          depth:         1,
          patient_name:  order.patient.full_name,
          drug:          "#{order.drug_name} #{order.dose}",
          raised_by:     current_user.full_name
        },
        happened_at: Time.current
      )
    end
    flash[:notice] = "Escalated to MD: #{order.drug_name} for #{order.patient.full_name}."
    redirect_back(fallback_location: dashboard_path)
  end
end
