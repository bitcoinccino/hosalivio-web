# Sweeps every active comfort-med order across every agency. For each
# order that is meaningfully overdue, fires an AgentEvent("handoff")
# targeted at the patient's assigned RN — and, for the worst cases,
# the assigned MD too.
#
# Idempotent: skips an order if a handoff for it has been emitted within
# the last 6 hours (avoid spamming a clinician with the same alert).
#
# Scheduled in config/recurring.yml. Run on demand:
#   bin/rails runner 'OverdueMedicationSweepJob.perform_now'

class OverdueMedicationSweepJob < ApplicationJob
  queue_as :default

  # An order isn't "critical" the second the next-due time passes — clinicians
  # build slack into their day. We only escalate at 2x the dosing interval
  # (e.g. q4h med becomes critical at 8h overdue).
  CRITICAL_MULTIPLIER = 2.0

  # Severe — escalate to MD as well. e.g. q4h becomes MD-worthy at 24h.
  SEVERE_MINUTES = 24 * 60

  # Don't re-fire a handoff for the same order within this window.
  IDEMPOTENCY_WINDOW = 6.hours

  def perform
    fired_rn = 0
    fired_md = 0

    ActsAsTenant.without_tenant do
      Agency.where(active: true).find_each do |agency|
        ActsAsTenant.with_tenant(agency) do
          MedicationOrder.where(status: :active).includes(:patient, :medication_logs).find_each do |order|
            sched = MedicationSchedule.for(order)
            next unless sched[:status] == :overdue

            overdue_minutes  = -sched[:minutes].to_i
            interval_minutes = MedicationSchedule.interval_minutes(order.frequency).to_i
            critical_threshold = (interval_minutes * CRITICAL_MULTIPLIER).to_i

            next if interval_minutes <= 0
            next if overdue_minutes < critical_threshold

            # Idempotency: skip if a handoff for this order was emitted recently.
            existing = AgentEvent.where(
              agency:       agency,
              action:       "handoff",
              subject:      order
            ).where("happened_at > ?", IDEMPOTENCY_WINDOW.ago)

            next if existing.exists?

            severe = overdue_minutes >= SEVERE_MINUTES
            patient = order.patient
            rn = patient.assigned_rn
            md = patient.assigned_md if severe

            if rn
              fire_handoff(agency, order, "rn", rn, overdue_minutes, severe)
              fired_rn += 1
            end

            if md
              fire_handoff(agency, order, "md", md, overdue_minutes, severe, intent: "review_pain_regimen")
              fired_md += 1
            end
          end
        end
      end
    end

    Rails.logger.info("[OverdueMedicationSweepJob] fired RN=#{fired_rn} MD=#{fired_md}")
  end

  private

  def fire_handoff(agency, order, target_role, recipient, overdue_minutes, severe, intent: "med_overdue_critical")
    Current.agency           = agency
    Current.agent_id         = "system"
    Current.agent_session_id = "med-sweep-#{SecureRandom.hex(3)}"

    AgentEvent.create!(
      agency:           agency,
      agent_id:         "system",
      agent_session_id: Current.agent_session_id,
      action:           "handoff",
      subject:          order,
      change_set: {
        target_role:    target_role,
        target_user_id: recipient&.id,
        intent:         intent,
        urgency:        severe ? "crisis" : "urgent",
        depth:          1,
        patient_name:   order.patient.full_name,
        patient_id:     order.patient_id,
        drug:           "#{order.drug_name} #{order.dose}",
        route:          order.route,
        frequency:      order.frequency,
        overdue_label:  format_minutes(overdue_minutes),
        raised_by:      "Comfort-med safety sweep"
      },
      happened_at: Time.current
    )

    Notification.create!(
      agency:       agency,
      user:         recipient,
      kind:         "med_overdue_critical",
      title:        severe ? "Comfort med severely overdue" : "Comfort med overdue",
      body:         "#{order.patient.full_name} · #{order.drug_name} #{order.dose} #{order.route.to_s.upcase} · #{format_minutes(overdue_minutes)} overdue.",
      delivered_at: Time.current
    )
  rescue => e
    Rails.logger.warn("[OverdueMedicationSweepJob] handoff failed for order=#{order.id}: #{e.class} #{e.message}")
  end

  def format_minutes(mins)
    return "#{mins}m" if mins < 60
    h = mins / 60
    m = mins % 60
    m.zero? ? "#{h}h" : "#{h}h #{m}m"
  end
end
