class Inquiry < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail

  # PHI-light but still personal info. Encrypt at rest.
  encrypts :first_name
  encrypts :last_name
  encrypts :contact
  encrypts :caregiver_phone
  encrypts :email
  encrypts :dob                              # stored as a "YYYY-MM-DD" string
  encrypts :diagnosis
  encrypts :zip,      deterministic: true   # deterministic so we can prefix-filter later
  encrypts :question

  # Plain-language terminal-diagnosis buckets for the public form. These map
  # onto the CMS hospice-LCD terminal-status categories (see Cms::HospiceCoverage)
  # without making a family pick an ICD-10 code.
  DIAGNOSIS_OPTIONS = [
    "Cancer",
    "Heart disease (CHF)",
    "Lung disease (COPD)",
    "Dementia or Alzheimer's",
    "Stroke",
    "Parkinson's or ALS",
    "Kidney (renal) failure",
    "Liver disease",
    "General decline / weakness",
    "Other",
    "Not sure"
  ].freeze

  # Who is submitting the request — a family member or a referring clinician.
  REQUESTER_ROLE_OPTIONS = [
    "Caregiver or Family Member",
    "Physician",
    "Advanced Practice Provider",
    "Director of Nursing",
    "Nurse",
    "Social Worker",
    "Care Coordinator",
    "Healthcare Administrator"
  ].freeze

  validates :diagnosis,      inclusion: { in: DIAGNOSIS_OPTIONS },      allow_blank: true
  validates :requester_role, inclusion: { in: REQUESTER_ROLE_OPTIONS }, allow_blank: true

  enum :status, {
    new_lead:   0,
    claimed:    1,
    contacted:  2,
    converted:  3,
    dismissed:  4
  }, prefix: :status, validate: true

  belongs_to :agency
  belongs_to :claimed_by,        class_name: "User",    optional: true
  belongs_to :converted_patient, class_name: "Patient", optional: true

  validates :source_prompt, presence: true
  validates :contact,       presence: true

  # A new lead should light up the Mission Stage and the receiving agency's inbox.
  after_create_commit :fan_out

  def zip_prefix
    zip.to_s[0, 3]
  end

  # Shown to clinicians; hides raw PHI beyond first-name + zip prefix.
  def display_label
    name = first_name.presence || "Anonymous"
    "#{name}#{is_general ? ' (general inquiry)' : ''} · #{zip_prefix}xx"
  end

  private

  def fan_out
    # Synchronous: light up the Mission Stage for the receiving agency.
    InquiryProcessor.new(self).call
    # Async: page the on-call admissions (scheduling) coordinator immediately.
    InquiryAlertJob.perform_later(id, agency_id)
  end
end
