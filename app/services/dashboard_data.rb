# Single source for the data the My Day dashboard needs, so the
# controller and the live-broadcast hooks compile it the same way.
# Each method is a small focused query — callers pull only what
# they need (e.g. an overdue-meds broadcast doesn't recompute the
# handoffs list).
class DashboardData
  def self.for(user)
    new(user)
  end

  # Re-render an RN's live "Needs action now" card over their Turbo Stream.
  # Called from after_commit hooks (Note/MedicationLog/AgentEvent/Visit) so the
  # crisis / overdue / team-request / review counts update without a refresh.
  def self.broadcast_needs_action(rn)
    return unless rn
    Turbo::StreamsChannel.broadcast_replace_to(
      "dashboard:user:#{rn.id}",
      target:  "dashboard-needs-action-#{rn.id}",
      partial: "dashboards/needs_action_card",
      locals:  { data: self.for(rn), viewer_user_id: rn.id }
    )
  rescue => e
    Rails.logger.warn("[DashboardData.broadcast_needs_action] #{e.class}: #{e.message}")
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
              .where(agency_id: agency.id, action: "handoff", acknowledged_at: nil)
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

  def open_crises
    case_ids = caseload.pluck(:id)
    return Note.none if case_ids.empty?
    Note.unscoped.where(patient_id: case_ids, author_role: "family",
                        urgency: :crisis, read_at: nil)
        .order(created_at: :desc).limit(5).includes(:patient)
  end

  def charts_needing_review
    todays_visits.select { |v| v.completed_visit? && !v.chart_locked? && v.narrative.to_s.strip.present? }
  end
end
