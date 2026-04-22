class PatientChannel < ApplicationCable::Channel
  def subscribed
    patient_id = params[:patient_id]
    reject and return if patient_id.blank?
    # TODO: verify principal has access to this patient before streaming.
    stream_from "patient:#{patient_id}"
  end
end
