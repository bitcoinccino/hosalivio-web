# Mixed into the models whose changes are visible in the patient chart's
# right-rail clinical context (vitals, visits, meds, eval, DME, deliveries).
# On commit it pings the patient's chart channel so every open browser
# re-fetches the rail. The ping carries no PHI — see
# PatientChannel.broadcast_context_changed.
#
# A model with no direct patient_id (e.g. MedicationLog) overrides
# #patient_context_id to resolve it.
module BroadcastsPatientContext
  extend ActiveSupport::Concern

  included do
    after_commit :broadcast_patient_context_changed
  end

  private

  def broadcast_patient_context_changed
    PatientChannel.broadcast_context_changed(patient_context_id)
  rescue => e
    Rails.logger.warn("[BroadcastsPatientContext] #{e.class}: #{e.message}")
  end

  def patient_context_id
    patient_id
  end
end
