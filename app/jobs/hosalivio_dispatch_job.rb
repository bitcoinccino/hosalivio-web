# Background job for clinician-to-HosAlivio delegation. When Pascal
# tags @HosAlivio in his team-chat message, ClinicianMessagesController
# enqueues this job; we look up the note + the requester, then hand off
# to ClinicianDispatcher which classifies the intent and fires the
# matching AgentTriager action.
#
# Same shape as HosalivioTriageJob (the family-message path), just
# reading from a different author.

class HosalivioDispatchJob < ApplicationJob
  queue_as :default

  def perform(note_id, requester_id)
    note      = Note.unscoped.find_by(id: note_id)
    requester = User.find_by(id: requester_id)
    return unless note && requester

    ActsAsTenant.with_tenant(note.agency) do
      ClinicianDispatcher.call(note: note, requester: requester)
    end
  end
end
