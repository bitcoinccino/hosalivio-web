class PreAdmitEval < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail
  include BroadcastsPatientContext

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

  # Outbound EMR transmission lifecycle (mirrors the latest EmrSyncLog).
  #   not_synced → processing → synced | failed
  enum :sync_status, {
    not_synced: 0,
    processing: 1,
    synced:     2,
    failed:     3
  }, prefix: :sync, validate: true

  belongs_to :agency
  belongs_to :patient
  belongs_to :visit,        optional: true
  belongs_to :evaluator,    class_name: "User", optional: true
  belongs_to :certified_by, class_name: "User", optional: true

  # Polymorphic audit rows written by Signatures::Apply on RN
  # route-to-MD and MD certification. The eval document partial
  # renders the most recent of each verification_method.
  has_many :signatures, as: :signable, dependent: :destroy

  # Round-trip records when an MD asks the RN to revise. Open
  # rows surface as a banner on the visit edit page; closed rows
  # stay around for the audit trail.
  has_many :revision_requests, class_name: "EvalRevisionRequest", dependent: :destroy

  # Outbound EMR push receipts (VITAS portal, etc.)
  has_many :emr_sync_logs, dependent: :destroy

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
  def final_review_section; raw_json.dig("pre_admit_eval", "final_review")        || {}; end
  def referral_context    ; raw_json.dig("pre_admit_eval", "referral_context")    || {}; end
  def medicare_lcd        ; raw_json.dig("pre_admit_eval", "medicare_lcd_criteria") || {}; end
  def equipment           ; (general["equipment"].is_a?(Hash) ? general["equipment"] : {}) || {}; end

  # New fine-grained accessors aligned with the referral-stage
  # schema (chief_complaint, HPI, related/unrelated conditions,
  # fall_history, recent_functional_changes, etc.). These are all
  # additive to existing data — old evals with sparse keys still
  # render fine because every dig falls back to nil/empty.
  def chief_complaint            ; general_comments["chief_complaint"]; end
  def history_of_present_illness ; general_comments["history_of_present_illness"]; end
  def related_conditions         ; Array(diagnosis_section["related_conditions"]); end
  def unrelated_conditions       ; Array(diagnosis_section["unrelated_conditions"]); end
  def fall_history               ; functional_decline["fall_history"]; end
  def recent_functional_changes  ; functional_decline["recent_functional_changes"]; end

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

  # ── Required documents (MVP form tracking) ──────────────────────
  # A single view of the key admission forms and whether each is on file.
  # Election + Patient Rights are certification-BLOCKING; POLST / Advance
  # Directive / code status are care alerts (visible, not blocking). DNR is
  # the patient's code_status (no separate form), so it shows its value.
  def required_documents
    [
      { key: "election_of_benefits", label: "Election of Benefits", on_file: election_signed?,                blocking: true },
      { key: "patient_rights",       label: "Patient Rights",       on_file: patient_rights_reviewed?,        blocking: true },
      { key: "polst",                label: "POLST",                on_file: patient&.polst_on_file == true,  blocking: false },
      { key: "advance_directive",    label: "Advance Directive",    on_file: patient&.advance_directive_on_file == true, blocking: false },
      { key: "code_status",          label: "Code status / DNR",    on_file: patient&.code_status.present?,   blocking: false,
        value: patient&.code_status.to_s.tr("_", " ").upcase.presence }
    ]
  end

  # Labels of forms not yet on file (care alerts + blockers), for @HosAlivio
  # and the "missing documents" summaries. Code status is never "missing"
  # (it always has a value), so it won't appear here.
  def missing_required_documents
    required_documents.reject { |d| d[:on_file] }.map { |d| d[:label] }
  end

  def can_certify?
    certification_blockers.empty?
  end

  # Human-readable summary for Mission Stage cards
  def headline
    dx = primary_icd10_description.presence || primary_icd10.presence || "diagnosis pending"
    "Pre-admit: #{patient.full_name} · #{dx}"
  end

  # ── External EMR push (VITAS) ───────────────────────────────────

  # Builds the outbound payload for the external EMR gateway. Shaped loosely
  # on a FHIR Encounter; the full clinical detail rides in raw_json (the
  # structured eval we already produce). Pure read — no side effects.
  def compile_vitas_payload
    {
      resource_type:      "Encounter",
      provider_eval_id:   id,
      tenant_provider_id: agency_id,
      generated_at:       Time.current.iso8601,
      patient: {
        mrn:  patient&.mrn,
        name: patient&.full_name,
        dob:  patient&.try(:dob)&.iso8601
      },
      encounter: {
        visit_id:          visit_id,
        visit_type:        visit&.visit_type,
        date_of_service:   (evaluated_at || created_at)&.iso8601,
        clinician_name:    evaluator_name,
        clinician_role:    evaluator_role,
        clinician_license: evaluator_license
      },
      eligibility: {
        primary_diagnosis: {
          icd10:       primary_icd10,
          description: primary_icd10_description
        },
        lcd_criteria_supported: lcd_criteria_supported,
        certified_at:           certified_at&.iso8601,
        certified_by:           certified_by&.full_name
      },
      clinical_detail: raw_json,
      status:          status
    }
  end

  # Fire-and-forget push to the external EMR. No-ops unless the VITAS gateway
  # is configured (env), so it's safe to call from the certify flow today and
  # starts transmitting the moment credentials are set.
  def enqueue_emr_sync
    return false unless VitasEmrSyncJob.configured?
    VitasEmrSyncJob.perform_later(id)
    true
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
