# Consumes the signed token from a Telegram / SMS / email ping.
# Verifies the token is non-expired + non-consumed, signs in the
# linked user (Devise), marks the ping consumed, and redirects to
# the right destination (notifications inbox by default; a targeted
# URL when the ping has one stored in payload).
#
# Audit-logged via AgentEvent so we have a record of which ping
# initiated which session, on which IP, with which user-agent. PHI-
# free at every step: the token itself does not leak any patient
# detail, and the redirect goes to an authenticated surface.
class InboxLinksController < ApplicationController
  # Bypass Devise's default sign-in requirement for the consumption
  # flow itself; we'll sign the user in once the token validates.
  skip_before_action :authenticate_user!, raise: false

  def show
    token = params[:t].to_s
    if token.blank?
      redirect_to(new_user_session_path, alert: "That link is missing a token.") and return
    end

    ping = OutboundPing.unscoped.find_by(link_token: token)

    if ping.nil?
      log_audit(nil, "deeplink_invalid", reason: "not_found")
      redirect_to(new_user_session_path, alert: "We couldn't find that link. It may have already been used or expired.") and return
    end

    unless ping.usable?
      reason = ping.expired? ? "expired" : "already_consumed"
      log_audit(ping, "deeplink_invalid", reason: reason)
      redirect_to(new_user_session_path, alert: "That link is no longer valid. Please sign in to continue.") and return
    end

    user = ping.user
    if user.nil? || !user.active
      log_audit(ping, "deeplink_invalid", reason: "user_inactive")
      redirect_to(new_user_session_path, alert: "We couldn't sign you in from that link.") and return
    end

    # Mark consumed FIRST so a double-click can't authenticate twice.
    # Devise sign_in still works after this; the token is only used
    # to authorize the session start, not to maintain it.
    ping.consume!
    sign_in(user, scope: :user)
    log_audit(ping, "deeplink_consumed")

    redirect_to(destination_for(ping), notice: "Signed in. Here's what's waiting for you.")
  end

  private

  # Where to land the user post-sign-in. Order:
  #   1. payload.target_path (explicit, set by the enqueuer)
  #   2. patient_chat for note_id payloads
  #   3. pre_admit_eval for cert handoffs
  #   4. notifications inbox as the safe default
  def destination_for(ping)
    payload = ping.payload || {}
    return payload["target_path"] if payload["target_path"].is_a?(String) && payload["target_path"].start_with?("/")

    case payload["source"]
    when "note_mention"
      note = Note.unscoped.find_by(id: payload["note_id"])
      patient_chat_path(note.patient_id) if note
    when "notification"
      n = Notification.unscoped.find_by(id: payload["notification_id"])
      if n&.linked_type == "PreAdmitEval"
        pre_admit_eval_path(n.linked_id)
      elsif n&.linked_type == "Patient"
        patient_chat_path(n.linked_id)
      end
    end || notifications_path
  end

  def log_audit(ping, action, **extra)
    AgentEvent.create!(
      agency:      ping&.agency || Current.agency || Agency.first,
      agent_id:    "inbox_link",
      action:      action,
      subject:     ping,
      happened_at: Time.current,
      change_set: {
        ip:         request.remote_ip,
        user_agent: request.user_agent.to_s[0, 200],
        ping_kind:  ping&.kind,
        user_id:    ping&.user_id
      }.merge(extra)
    )
  rescue => e
    Rails.logger.warn("[InboxLinksController] audit log failed: #{e.message}")
  end
end
