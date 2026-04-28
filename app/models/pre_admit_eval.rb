class PreAdmitEval < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail

  # State machine for the certification chain:
  # draft      → Pascal still capturing
  # final      → Pascal submitted; waiting on Esther to certify
  # certified  → Esther signed CoE; waiting on Kendra to file NOE
  # noe_filed  → Kendra filed Medicare NOE; patient is officially on hospice benefit
  # revoked    → Patient/family revoked before NOE filed (rare)
  enum :status, {
    draft:     0,
    final:     1,
    certified: 2,
    noe_filed: 3,
    revoked:   4
  }, prefix: true, validate: true

  belongs_to :agency
  belongs_to :patient
  belongs_to :visit,        optional: true
  belongs_to :evaluator,    class_name: "User", optional: true
  belongs_to :certified_by, class_name: "User", optional: true

  validates :raw_json, presence: true
  validates :evaluator_name, presence: true, if: -> { status_final? || status_certified? || status_noe_filed? }

  # NOE filing deadline is 5 calendar days from patient election.
  # We use evaluated_at as a proxy for election date; operationally these match.
  NOE_WINDOW_DAYS = 5

  before_validation :stamp_noe_deadline,  on: :create
  before_save       :sync_summary_from_json

  # Convenience timestamps for the UI
  def days_until_noe_deadline
    return nil unless noe_deadline_at
    ((noe_deadline_at - Time.current) / 1.day).ceil
  end

  def noe_overdue?
    noe_deadline_at && Time.current > noe_deadline_at && !status_noe_filed?
  end

  # ── Section accessors (new section-based schema) ────────────────

  def header              ; raw_json.dig("pre_admit_eval", "header")              || {}; end
  def general_comments    ; raw_json.dig("pre_admit_eval", "general_comments")    || {}; end
  def diagnosis_section   ; raw_json.dig("pre_admit_eval", "diagnosis")           || {}; end
  def current_medications ; Array(raw_json.dig("pre_admit_eval", "current_medications")); end
  def discontinued_meds   ; Array(raw_json.dig("pre_admit_eval", "discontinued_meds")); end
  def other_symptoms      ; raw_json.dig("pre_admit_eval", "other_symptoms")      || {}; end
  def cognitive_decline   ; raw_json.dig("pre_admit_eval", "cognitive_decline")   || {}; end
  def nutritional_decline ; raw_json.dig("pre_admit_eval", "nutritional_decline") || {}; end
  def functional_decline  ; raw_json.dig("pre_admit_eval", "functional_decline")  || {}; end
  def general             ; raw_json.dig("pre_admit_eval", "general")             || {}; end

  def pps_object          ; functional_decline["pps"]; end
  def pps_score
    case pps_object
    when Integer then pps_object
    when Hash    then pps_object["score"].to_i.nonzero?
    end
  end

  # ── Certification gate (new schema) ─────────────────────────────
  # CMS still requires election + signed Notice of Election + a
  # supported terminal prognosis. The new schema collapses old
  # informed_consent / financial_consent into a thinner `general`
  # block; we keep the gate aligned to that.

  def election_signed?
    general["election_of_benefits_signed"] == true
  end

  def patient_rights_reviewed?
    general["patient_rights_reviewed"] == true
  end

  # Returns an array of specific blockers; empty array means certify-ready.
  def certification_blockers
    blockers = []
    blockers << "Election of benefits not signed"  unless election_signed?
    blockers << "Patient rights not reviewed"      unless patient_rights_reviewed?
    blockers << "Primary diagnosis ICD-10 missing" if primary_icd10.blank?
    blockers << "LCD criteria not supported"       unless lcd_criteria_supported
    blockers
  end

  def can_certify?
    certification_blockers.empty?
  end

  # Human-readable summary for Mission Stage cards
  def headline
    dx = primary_icd10_description.presence || primary_icd10.presence || "diagnosis pending"
    "Pre-admit: #{patient.full_name} · #{dx}"
  end

  private

  def stamp_noe_deadline
    self.noe_deadline_at ||= (evaluated_at || Time.current) + NOE_WINDOW_DAYS.days
  end

  # Pull primary_icd10 + description + LCD flag out of the JSON each save
  # so SQL queries can filter without having to jsonb-dig every row.
  # New schema nests diagnosis fields:
  #   diagnosis.primary_terminal_diagnosis.{description,icd10}
  #   diagnosis.lcd_criteria_met (array of strings)
  def sync_summary_from_json
    return unless raw_json.is_a?(Hash)
    dx       = raw_json.dig("pre_admit_eval", "diagnosis") || {}
    primary  = dx["primary_terminal_diagnosis"].is_a?(Hash) ? dx["primary_terminal_diagnosis"] : {}
    lcd_list = Array(dx["lcd_criteria_met"])

    self.primary_icd10             = primary["icd10"].to_s.presence
    self.primary_icd10_description = primary["description"].to_s.presence
    self.lcd_criteria_supported    = lcd_list.any?
  end
end
