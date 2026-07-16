# Pushes "still deciding" hospice leads back to a human when their follow-up
# date arrives. A `considering` Inquiry is parked with a follow_up_at date so it
# doesn't go cold; until now that only surfaced passively in the inbox. This
# sweep turns it into an active nudge.
#
# For every considering inquiry whose follow_up_at has come due it alerts the
# on-call admissions coordinator (falling back to all admissions coordinators so
# a lead is never dropped) via Notification — which fans out to the in-app bell
# plus the recipient's outbound channel, exactly like InquiryAlertJob.
#
# Idempotent per calendar day (one Notification per inquiry + user + day), so a
# lead that stays due re-nudges DAILY until the coordinator reconnects, converts,
# dismisses, or reschedules it — but a single run never spams.
class FollowUpDueSweepJob < ApplicationJob
  queue_as :default

  KIND = "inquiry_follow_up_due"

  def perform
    sent = 0
    ActsAsTenant.without_tenant do
      Agency.where(active: true).find_each do |agency|
        ActsAsTenant.with_tenant(agency) do
          Inquiry.status_considering
                 .where.not(follow_up_at: nil)
                 .where("follow_up_at <= ?", Time.current)
                 .find_each do |inquiry|
            sent += alert(agency, inquiry)
          end
        end
      end
    end
    Rails.logger.info("[FollowUpDueSweepJob] alerts_sent=#{sent}")
  end

  private

  def alert(agency, inquiry)
    recipients(agency).sum do |user|
      next 0 if already_alerted_today?(inquiry, user)
      Notification.create!(
        agency:       agency,
        user:         user,
        kind:         KIND,
        title:        title_for(inquiry),
        body:         body_for(inquiry),
        linked:       inquiry,
        delivered_at: Time.current
      )
      1
    end
  end

  # On-call admissions coordinator(s), else every admissions coordinator so a
  # due follow-up is never silently dropped.
  def recipients(agency)
    on_call = admissions_coordinators(agency).merge(User.on_call_now)
    on_call.exists? ? on_call : admissions_coordinators(agency)
  end

  # Explicit agency_id scope so global/system-admin users (nil agency) are excluded.
  def admissions_coordinators(agency)
    User.where(agency_id: agency.id, active: true)
        .joins(:roles).where(roles: { name: "admissions" }).distinct
  end

  # Re-nudge daily: the idempotency shield expires at midnight, so the first
  # sweep each calendar day re-alerts an still-open follow-up.
  def already_alerted_today?(inquiry, user)
    Notification.where(kind: KIND, linked_type: "Inquiry", linked_id: inquiry.id, user_id: user.id)
                .where("created_at >= ?", Date.current.beginning_of_day)
                .exists?
  end

  def title_for(inquiry)
    "Follow-up due · #{inquiry.display_label}"
  end

  def body_for(inquiry)
    days = ((Time.current - inquiry.follow_up_at) / 1.day).floor
    when_txt = days <= 0 ? "today" : "#{days} day#{'s' if days != 1} ago"
    "#{inquiry.display_label} was weighing hospice — the follow-up you set came due #{when_txt}. " \
      "Reconnect, convert them to a patient, or reschedule the follow-up."
  end
end
