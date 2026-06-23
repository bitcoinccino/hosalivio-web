class ClinicianMessageResponseJob < ApplicationJob
  queue_as :default

  def perform(note_id, requester_id, action, ack = nil)
    note = Note.unscoped.find_by(id: note_id)
    requester = User.unscoped.find_by(id: requester_id)
    return unless note && requester && action.present? && action != "no_action"

    ActsAsTenant.with_tenant(note.agency) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      action, ack = classify_action(note, requester) if action.to_s == "classify"
      if action.blank? || action == "no_action"
        broadcast_idle(note)
        return
      end

      result = ClinicianDispatcher.execute(
        note: note,
        requester: requester,
        action: action,
        ack: ack
      )
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      Rails.logger.info(
        "[ClinicianMessageResponseJob] note=#{note.id} action=#{action} dispatched=#{result.dispatched} elapsed_ms=#{elapsed_ms}"
      )
    end
  rescue => e
    Rails.logger.warn("[ClinicianMessageResponseJob] #{e.class}: #{e.message}")
  end

  private

  def classify_action(note, requester)
    decision = HosalivioBrain.classify_clinician_message(note: note, requester: requester)
    action = decision[:action].to_s.presence || "no_action"
    [action, decision[:ack]]
  rescue => e
    Rails.logger.warn("[ClinicianMessageResponseJob#classify_action] #{e.class}: #{e.message}")
    ["no_action", nil]
  end

  def broadcast_idle(note)
    ActionCable.server.broadcast(
      "patient:#{note.patient_id}",
      { kind: "hosalivio_idle", note_id: note.id }
    )
  end
end
