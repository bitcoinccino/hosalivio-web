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

  # Human-readable summary for Mission Stage cards
  def headline
    dx = primary_icd10_description.presence || primary_icd10.presence || "diagnosis pending"
    "Pre-admit: #{patient.full_name} · #{dx}"
  end

  private

  def stamp_noe_deadline
    self.noe_deadline_at ||= (evaluated_at || Time.current) + NOE_WINDOW_DAYS.days
  end

  # Pull the primary_icd10 + description + LCD flag out of the JSON each save
  # so SQL queries can filter without having to jsonb-dig every row.
  def sync_summary_from_json
    return unless raw_json.is_a?(Hash)
    dx = raw_json.dig("pre_admit_eval", "diagnosis") || {}
    lcd = raw_json.dig("pre_admit_eval", "medicare_lcd_criteria") || {}

    self.primary_icd10             = dx["primary_icd10"].to_s.presence
    self.primary_icd10_description = dx["primary_icd10_description"].to_s.presence
    self.lcd_criteria_supported    = Array(lcd["criteria_met"]).any? || lcd["supporting_documentation"].to_s.strip.present?
  end
end
