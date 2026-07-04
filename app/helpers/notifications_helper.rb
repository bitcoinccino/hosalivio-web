module NotificationsHelper
  # Where a notification takes you when clicked. Note-linked notifications
  # (mentions, replies, HosAlivio flags) deep-link to the exact message in
  # the patient chat via ?note=<id>, which the chat scrolls to + highlights.
  # Other kinds go to their natural home. Always returns a usable path.
  def notification_target_path(notification)
    case notification.linked_type
    when "Note"
      pid = notification.linked&.patient_id
      pid ? patient_path(pid, note: notification.linked_id) : notifications_path
    when "Visit"
      notification.linked_id ? visit_path(notification.linked_id) : notifications_path
    when "PreAdmitEval"
      notification.linked_id ? pre_admit_eval_path(notification.linked_id) : notifications_path
    when "Patient"
      notification.linked_id ? patient_path(notification.linked_id) : notifications_path
    when "ChannelMessage"
      notification.linked&.channel ? channel_path(notification.linked.channel) : notifications_path
    else
      notifications_path
    end
  end
end
