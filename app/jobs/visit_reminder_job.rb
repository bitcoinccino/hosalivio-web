# Daily 24-hour horizon reminder.
#
# Runs once per day (scheduled from config/recurring.yml in production;
# can be triggered manually via `bin/rails runner 'VisitReminderJob.perform_now'`).
#
# For every visit scheduled for the NEXT calendar day, fires three things:
#   1. In-app Notification on the clinician's dashboard (persisted row)
#   2. Email reminder via ActionMailer (letter_opener in dev, real SMTP in prod)
#   3. SMS stub via Rails.logger (real provider wiring is Phase 4)
#
# Idempotent: if a reminder was already delivered for a visit+kind, skip.

class VisitReminderJob < ApplicationJob
  queue_as :default

  KIND = "visit_reminder_24h"

  def perform(target_date: Date.current + 1)
    start_of_day = target_date.in_time_zone.beginning_of_day
    end_of_day   = target_date.in_time_zone.end_of_day

    sent_count    = 0
    skipped_count = 0

    ActsAsTenant.without_tenant do
      # Scan every agency; each Notification lands in the clinician's own agency scope.
      Agency.where(active: true).find_each do |agency|
        ActsAsTenant.with_tenant(agency) do
          visits = Visit
                     .where("COALESCE(scheduled_at, started_at) BETWEEN ? AND ?", start_of_day, end_of_day)
                     .includes(:patient, :user)

          visits.each do |visit|
            next if visit.user_id.blank?
            if already_reminded?(visit)
              skipped_count += 1
              next
            end
            deliver(visit)
            sent_count += 1
          end
        end
      end
    end

    Rails.logger.info("[VisitReminderJob] date=#{target_date} sent=#{sent_count} skipped=#{skipped_count}")
  end

  private

  def already_reminded?(visit)
    Notification.where(linked_type: "Visit", linked_id: visit.id, kind: KIND).exists?
  end

  def deliver(visit)
    title = reminder_title(visit)
    body  = reminder_body(visit)

    # 1. In-app notification (persisted, appears in the clinician's bell)
    notification = Notification.create!(
      agency:        visit.agency,
      user:          visit.user,
      kind:          KIND,
      title:         title,
      body:          body,
      linked:        visit,
      delivered_at:  Time.current
    )

    # 2. Email via letter_opener (dev) / real SMTP (prod)
    begin
      VisitReminderMailer.with(visit: visit).tomorrow_reminder.deliver_later
    rescue => e
      Rails.logger.warn("[VisitReminderJob] email delivery failed for visit=#{visit.id}: #{e.class} #{e.message}")
    end

    # 3. SMS stub (real provider wiring is Phase 4)
    phone = visit.user.respond_to?(:phone) ? visit.user.try(:phone) : nil
    Rails.logger.info(
      "[SMS Reminder stub] to=#{phone || visit.user.email} " \
      "for=#{visit.user.full_name} re=patient '#{visit.patient&.full_name}' " \
      "at=#{visit.anchor_start&.strftime('%Y-%m-%d %-l:%M %p')} provenance=#{visit.agent_authored ? 'suggested_by_hosalivio' : 'scheduled_by_staff'} " \
      "notification_id=#{notification.id}"
    )
  end

  # Prefer the patient's branch timezone (branch is the physical site running
  # the visit); fall back to clinician tz, then UTC.
  def local_tz(visit)
    visit.patient&.branch&.timezone.presence ||
      visit.user&.try(:timezone).presence ||
      "UTC"
  end

  def reminder_title(visit)
    tz = local_tz(visit)
    "Tomorrow #{visit.anchor_start&.in_time_zone(tz)&.strftime('%-l:%M %p %Z')} · #{visit.patient&.full_name}"
  end

  def reminder_body(visit)
    tz = local_tz(visit)
    provenance = visit.agent_authored ?
      "Scheduled by AI (review or adjust in the calendar if needed)." :
      "Scheduled by a human."
    [
      "#{visit.discipline.to_s.upcase} visit with #{visit.patient&.full_name} (MRN #{visit.patient&.mrn}).",
      "Time: #{visit.anchor_start&.in_time_zone(tz)&.strftime('%A %b %-d, %-l:%M %p %Z')}.",
      visit.visit_type.to_s != "routine" ? "Type: #{visit.visit_type.to_s.tr('_', ' ')}." : nil,
      provenance
    ].compact.join(" ")
  end
end
