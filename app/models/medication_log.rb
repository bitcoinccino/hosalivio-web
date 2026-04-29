class MedicationLog < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail
  include AgentAuditable

  # AgentAuditable expects agency_id directly; medication_log has it.

  enum :source, {
    comfort_kit: 0, home_supply: 1, pharmacy_delivery: 2
  }, prefix: true, validate: true

  belongs_to :agency
  belongs_to :medication_order
  belongs_to :administered_by, class_name: "User"

  has_one :patient, through: :medication_order

  validates :administered_at, :dose_given, presence: true

  # Live-update My Day for the patient's assigned RN — when a med
  # gets logged the row should drop off their Overdue Comfort Meds
  # card without a page reload.
  after_create_commit :broadcast_dashboard_overdue_change

  def broadcast_dashboard_overdue_change
    rn = medication_order.patient&.assigned_rn
    return unless rn
    data = DashboardData.for(rn)
    Turbo::StreamsChannel.broadcast_replace_to(
      "dashboard:user:#{rn.id}",
      target:  "dashboard-overdue-meds-#{rn.id}",
      partial: "dashboards/overdue_meds_card",
      locals:  { overdue_meds: data.overdue_meds, viewer_user_id: rn.id }
    )
  rescue => e
    Rails.logger.warn("[MedicationLog#broadcast_dashboard_overdue_change] #{e.class}: #{e.message}")
  end
end
