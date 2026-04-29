# Single source for the data the My Day dashboard needs, so the
# controller and the live-broadcast hooks compile it the same way.
# Each method is a small focused query — callers pull only what
# they need (e.g. an overdue-meds broadcast doesn't recompute the
# handoffs list).
class DashboardData
  def self.for(user)
    new(user)
  end

  attr_reader :user, :agency

  def initialize(user)
    @user   = user
    @agency = user.agency
  end

  def todays_visits
    today_range = Time.current.beginning_of_day..Time.current.end_of_day
    Visit.unscoped
         .where(agency_id: agency.id, user_id: user.id)
         .where(scheduled_at: today_range)
         .order(:scheduled_at)
  end

  def caseload
    Patient.unscoped.where(agency_id: agency.id, assigned_rn_id: user.id)
  end

  def pending_handoffs
    role_keys = user.role_names
    AgentEvent.unscoped
              .where(agency_id: agency.id, action: "handoff")
              .where("change_set->>'target_role' IN (?)", role_keys)
              .order(happened_at: :desc)
              .limit(50)
  end

  def overdue_meds
    case_ids = caseload.pluck(:id)
    return [] if case_ids.empty?
    orders = MedicationOrder.unscoped
                            .where(agency_id: agency.id, status: :active, patient_id: case_ids)
                            .includes(:medication_logs, :patient)
    overdue = orders.map do |o|
      sched = MedicationSchedule.for(o)
      { order: o, schedule: sched } if sched[:status] == :overdue
    end.compact
    overdue.sort_by { |r| r[:schedule][:minutes].to_i }.first(5)
  end
end
