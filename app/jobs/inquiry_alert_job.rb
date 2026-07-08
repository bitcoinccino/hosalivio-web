# A callback request from the public landing page (an Inquiry) should reach a
# human fast. The moment the lead is committed, Inquiry#fan_out enqueues this
# job, which pages the on-call admissions coordinator — the "scheduling
# coordinator" who owns first contact — in the receiving agency.
#
# Creating a Notification does the real fan-out for us: an instant in-app toast
# on the recipient's bell, plus an OutboundPing to their preferred channel
# (SMS / Telegram / email). We keep the preview PHI-light; the caller's contact
# details stay behind the deeplink to the inquiry.
#
# Tenant-safe: we take ids (not the record) so deserialization never depends on
# an ambient tenant, then re-enter the agency tenant explicitly.

class InquiryAlertJob < ApplicationJob
  queue_as :default

  KIND = "inquiry_callback_request"

  def perform(inquiry_id, agency_id)
    agency = Agency.find_by(id: agency_id)
    return unless agency

    ActsAsTenant.with_tenant(agency) do
      inquiry = Inquiry.find_by(id: inquiry_id)
      return unless inquiry

      recipients = on_call_coordinators(agency)
      if recipients.empty?
        # Never drop a lead: if nobody is flagged on-call, fall back to every
        # admissions coordinator so the request is still seen.
        recipients = admissions_coordinators(agency)
        Rails.logger.warn(
          "[InquiryAlertJob] no on-call admissions coordinator for agency=#{agency.id} " \
          "inquiry=#{inquiry.id}; fell back to #{recipients.size} admissions user(s)"
        )
      end

      routed_branch = Branch.route_for_zip(agency, inquiry.zip)
      delivered = 0
      recipients.each do |user|
        next if already_alerted?(inquiry, user)
        Notification.create!(
          agency:       agency,
          user:         user,
          kind:         KIND,
          title:        alert_title(inquiry),
          body:         alert_body(inquiry, routed_branch),
          linked:       inquiry,
          delivered_at: Time.current
        )
        delivered += 1
      end

      Rails.logger.info(
        "[InquiryAlertJob] inquiry=#{inquiry.id} agency=#{agency.id} " \
        "branch=#{routed_branch&.name.inspect} alerted=#{delivered}"
      )
    end
  end

  private

  # On-call admissions coordinators in THIS agency. Explicit agency_id scope so
  # global/system-admin users (nil agency, visible via has_global_records) are
  # excluded.
  def on_call_coordinators(agency)
    admissions_coordinators(agency).merge(User.on_call_now)
  end

  def admissions_coordinators(agency)
    User.where(agency_id: agency.id, active: true)
        .joins(:roles).where(roles: { name: "admissions" })
        .distinct
  end

  def already_alerted?(inquiry, user)
    Notification.where(kind: KIND, linked_type: "Inquiry", linked_id: inquiry.id, user_id: user.id).exists?
  end

  def alert_title(inquiry)
    "Callback requested · #{inquiry.zip_prefix}xx"
  end

  def alert_body(inquiry, routed_branch)
    window = inquiry.preferred_window_label
    [
      "#{inquiry.display_label} asked for a callback.",
      window ? "Preferred time: #{window}." : nil,
      routed_branch ? "Routed to #{routed_branch.name}." : nil,
      "Open to see how to reach them."
    ].compact.join(" ")
  end
end
