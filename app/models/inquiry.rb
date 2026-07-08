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
  # Inbound-referral fields (FHIR ingest).
  encrypts :external_mrn, deterministic: true  # deterministic so a coordinator can match on it
  encrypts :referring_provider
  encrypts :reason_for_referral
  encrypts :raw_fhir_payload                    # raw inbound payload, audit blob (PHI → encrypted)

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

  # FHIR ServiceRequest.priority value set.
  URGENCY_LEVELS = %w[routine urgent asap stat].freeze

  validates :diagnosis,      inclusion: { in: DIAGNOSIS_OPTIONS },      allow_blank: true
  validates :requester_role, inclusion: { in: REQUESTER_ROLE_OPTIONS }, allow_blank: true
  validates :urgency,        inclusion: { in: URGENCY_LEVELS },         allow_blank: true

  # "Book a Call" preferred-window slots for the public page. These are a
  # preference the family picks ("when's best to reach you?"), not a committed
  # appointment — a coordinator still owns first contact. Key is stored;
  # CALL_SLOTS maps it to the human label shown to family and staff.
  CALL_SLOTS = {
    "morning"   => "9-11 AM",
    "afternoon" => "1-3 PM",
    "evening"   => "4-6 PM"
  }.freeze
  validates :preferred_slot, inclusion: { in: CALL_SLOTS.keys }, allow_blank: true

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
  # A callback lead needs a way to reach the family; an inbound FHIR referral is
  # provider-originated, so the referring provider is the contact of record and
  # patient contact may legitimately be absent (graceful degradation — maximize
  # top-of-funnel intake). external_referral_id marks a referral-sourced lead.
  validates :contact, presence: true, unless: -> { external_referral_id.present? }

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

  # Human label for the preferred callback window, e.g. "Thu, Jul 9 · 1-3 PM".
  # nil when the family didn't pick one (a plain "call me back" lead).
  def preferred_window_label
    parts = []
    parts << preferred_date.strftime("%a, %b %-d") if preferred_date.present?
    parts << CALL_SLOTS[preferred_slot]            if preferred_slot.present?
    parts.join(" · ").presence
  end

  # Sort key so booked calls float to the top of the queue by soonest window;
  # unscheduled leads sort after any scheduled ones.
  def preferred_window_at
    return nil if preferred_date.blank?
    hour = { "morning" => 9, "afternoon" => 13, "evening" => 16 }[preferred_slot] || 9
    preferred_date.in_time_zone.change(hour: hour)
  end

  private

  def fan_out
    # Synchronous: light up the Mission Stage for the receiving agency.
    InquiryProcessor.new(self).call
    # Async: page the on-call admissions (scheduling) coordinator immediately.
    InquiryAlertJob.perform_later(id, agency_id)
  end
end
