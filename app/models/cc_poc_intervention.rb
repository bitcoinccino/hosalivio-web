# A PIE intervention row (Problem → Intervention → Evaluation) within a CC
# shift. Levels follow the VITAS scoring key; CNAs may not document meds.
class CcPocIntervention < ApplicationRecord
  acts_as_tenant :agency
  belongs_to :agency
  belongs_to :cc_interval_chart
  belongs_to :medication_order, optional: true   # cross-ref the patient's order/MAR

  # Who administered: a nurse (records med + dose + response) vs a caregiver/HA
  # (the response is forced to the required phrase — see CAREGIVER_PHRASE).
  enum :med_source, { nurse: 0, caregiver: 1 }, prefix: true, validate: true

  CAREGIVER_PHRASE = "Patient or Caregiver Indicated They Provided".freeze

  # Pain/symptom level accepts a 0-10 score OR a word scale.
  VALID_LEVELS = (%w[None Mild Moderate Severe] + (0..10).map(&:to_s)).freeze
  validates :initial_level, :post_level,
            inclusion: { in: VALID_LEVELS, allow_blank: true,
                         message: "must be 0-10, None, Mild, Moderate, or Severe" }

  # CNA medication boundary: keyed off the charting user's role (there is no
  # User#discipline). A CNA (aide) may not document medications.
  validate :cna_cannot_document_meds

  private

  def cna_cannot_document_meds
    charting_user = cc_interval_chart&.user
    return unless charting_user&.role_names&.include?("aide")
    if med_name_and_dose.present? || med_source_nurse?
      errors.add(:base, "CNAs cannot document medications — notify the LPN or RN.")
    end
  end
end
