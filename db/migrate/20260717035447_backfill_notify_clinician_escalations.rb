# HosalivioTriager#execute_notify wakes a named clinician — it posts a chart
# note and creates a Notification — but until now it wrote no AgentEvent. So
# those escalations were absent from the agent audit trail: invisible on the
# Mission Stage feed and unprovable from AgentEvent, even though a real nurse
# really was paged. `emit_handoff` recorded its escalations; this path didn't.
#
# The code now emits `notify_clinician` alongside the Notification. This
# reconstructs the ones that already happened, so AgentEvent.escalations answers
# "which humans did HosAlivio wake, and why?" for history too — not just going
# forward.
#
# Reconstructed from the Notification and its linked Note:
#   user            -> target_user_id / target_name
#   linked note     -> subject (its patient) and happened_at
#   body            -> reason, minus the "Patient Name: " prefix
#   user's role     -> target_role
#
# agent_session_id is marked `backfill-notify-*` rather than invented, because
# the original session id is genuinely unknown — provenance queries must be able
# to tell a reconstructed row from a recorded one.
class BackfillNotifyClinicianEscalations < ActiveRecord::Migration[8.1]
  TITLE_MATCH = "%flagged a patient%".freeze

  def up
    say_with_time "reconstructing notify-path escalations" do
      ActsAsTenant.without_tenant { backfill }
    end
  end

  # Only removes what this migration created — the marker makes that exact.
  def down
    say_with_time "removing reconstructed escalations" do
      ActsAsTenant.without_tenant do
        AgentEvent.where(action: "notify_clinician")
                  .where("agent_session_id LIKE ?", "backfill-notify-%")
                  .delete_all
      end
    end
  end

  private

  def backfill
    created = 0
    Notification.where(kind: "mentioned").where("title LIKE ?", TITLE_MATCH).find_each do |notif|
      note = notif.linked
      next unless note.is_a?(Note) && note.patient_id.present?

      marker = "backfill-notify-#{notif.id.to_s.delete('-')[0, 12]}"
      next if AgentEvent.where(agent_session_id: marker).exists?   # idempotent

      # "Maria Gonzalez: family is asking about timing" -> the reason only.
      reason = notif.body.to_s.split(": ", 2).last.to_s.strip.presence

      AgentEvent.create!(
        agency_id:        notif.agency_id,
        agent_id:         "triage",
        agent_session_id: marker,
        action:           "notify_clinician",
        subject_type:     "Patient",
        subject_id:       note.patient_id,
        change_set: {
          "target_role"    => notif.user&.roles&.first&.name,
          "target_user_id" => notif.user_id,
          "target_name"    => notif.user&.full_name,
          "reason"         => reason,
          "urgency"        => note.urgency.to_s,
          "reconstructed"  => true
        },
        happened_at: notif.created_at
      )
      created += 1
    end
    created
  end
end
