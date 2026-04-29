# Daily check for patients whose hospice cert window is closing.
# Creates one OutboundPing per (patient, assigned RN, milestone)
# pair on key milestone days (7 / 3 / 1 / day-of). Skips milestones
# the cron missed; doesn't backfill.
#
# Idempotent: re-running the same milestone for the same patient/RN
# doesn't double-ping. Uses payload[:milestone] as the dedup key.
#
# Usage:
#   bin/rake hosalivio:recert_reminders     # invoke from cron daily
#   RecertReminders.run_today                # programmatic
class RecertReminders
  MILESTONE_DAYS = [7, 3, 1, 0].freeze

  def self.run_today(today: Date.current)
    new(today: today).run
  end

  def initialize(today:)
    @today = today
  end

  def run
    enqueued = 0
    Patient.unscoped
           .where.not(cert_period_end: nil)
           .where(cert_period_end: @today..(@today + MILESTONE_DAYS.max.days))
           .find_each do |patient|
      days_left = (patient.cert_period_end - @today).to_i
      next unless MILESTONE_DAYS.include?(days_left)

      target = patient.assigned_rn
      next if target.nil? || !target.active

      payload = {
        source:          "recert_reminder",
        patient_id:      patient.id,
        days_left:       days_left,
        milestone:       days_left.to_s,
        cert_period_end: patient.cert_period_end.iso8601,
        target_path:     "/notifications"
      }

      # Dedup: don't re-enqueue the same (patient, milestone) on a
      # second run today. Looks at all OutboundPings (delivered or
      # not) for this user with the same milestone payload.
      already = OutboundPing.unscoped
                            .where(user_id: target.id, kind: "recert")
                            .where("created_at >= ?", @today.beginning_of_day)
                            .any? { |p| p.payload["milestone"].to_s == days_left.to_s && p.payload["patient_id"] == patient.id }
      next if already

      OutboundPing.create!(
        agency:  patient.agency,
        user:    target,
        kind:    "recert",
        preview: preview_for(days_left),
        payload: payload
      )
      enqueued += 1
    rescue => e
      Rails.logger.warn("[RecertReminders] failed for patient=#{patient.id}: #{e.message}")
    end
    Rails.logger.info("[RecertReminders] run_today: #{enqueued} ping(s) enqueued for #{@today.iso8601}")
    enqueued
  end

  private

  # PHI-free milestone preview. Patient name stays behind the
  # deeplink; the message just tells the RN something is due.
  def preview_for(days_left)
    case days_left
    when 0 then "Recertification visit due today for 1 patient"
    when 1 then "Recertification due tomorrow for 1 patient"
    else        "Recertification due in #{days_left} days for 1 patient"
    end
  end
end
