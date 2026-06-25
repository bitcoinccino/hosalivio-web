class ClinicianMessageResponseJob < ApplicationJob
  queue_as :default

  def perform(note_id, requester_id, action, ack = nil, notify = nil)
    note = Note.unscoped.find_by(id: note_id)
    requester = User.unscoped.find_by(id: requester_id)
    return unless note && requester && action.present? && action != "no_action"

    ActsAsTenant.with_tenant(note.agency) do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # A bare "yes"/"cancel" answering a pending relay preview short-
      # circuits classification: send (or drop) the drafted message
      # deterministically, no LLM. Checked first because the controller
      # may have already guessed "answer_question" for a bare affirmative.
      if (confirm = ClinicianDispatcher.relay_confirmation_for(note))
        action, ack, notify = confirm.to_s, nil, nil
      elsif action.to_s == "classify"
        action, ack, notify = classify_action(note, requester)
      end
      if action.blank? || action == "no_action"
        broadcast_idle(note)
        return
      end

      result = ClinicianDispatcher.execute(
        note: note,
        requester: requester,
        action: action,
        ack: ack,
        notify: notify
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
    [action, decision[:ack], decision[:notify]]
  rescue => e
    Rails.logger.warn("[ClinicianMessageResponseJob#classify_action] #{e.class}: #{e.message}")
    ["no_action", nil, nil]
  end

  def broadcast_idle(note)
    ActionCable.server.broadcast(
      "patient:#{note.patient_id}",
      { kind: "hosalivio_idle", note_id: note.id }
    )
  end
end
