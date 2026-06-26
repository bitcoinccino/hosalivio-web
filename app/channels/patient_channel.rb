class PatientChannel < ApplicationCable::Channel
  def subscribed
    patient_id = params[:patient_id]
    reject and return if patient_id.blank?
    # TODO: verify principal has access to this patient before streaming.
    stream_from "patient:#{patient_id}"
  end

  # Signal every open chart for this patient that its clinical context
  # (vitals, visits, meds, eval, crises…) changed. The payload carries NO
  # PHI — just a nudge. Each browser re-fetches the right-rail from
  # PatientChatsController#clinical_context, which re-applies the viewer's
  # own role scoping (family vs clinician). That per-viewer round-trip is
  # why we can't broadcast a pre-rendered rail: it would render one
  # viewer's version for everyone.
  def self.broadcast_context_changed(patient_id)
    return if patient_id.blank?
    ActionCable.server.broadcast("patient:#{patient_id}", { kind: "context_changed" })
  end
end
