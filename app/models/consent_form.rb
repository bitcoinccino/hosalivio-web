# Patient/family consent capture (Hospice Election, DNR, HIPAA,
# Plan of Care). Unlike clinician sign-offs we don't reuse a stored
# signature — patient/family always sign fresh, in front of a
# witnessing clinician (`witnessed_by`). The drawn signature image
# attaches to this record one-time; the audit metadata lands on a
# polymorphic `Signature` row exactly the same shape every other
# sign-off in the app uses.
class ConsentForm < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail

  belongs_to :patient
  belongs_to :witnessed_by, class_name: "User"
  belongs_to :agency

  has_one_attached :signature_image
  has_many :signatures, as: :signable, dependent: :destroy

  KINDS = %w[hospice_election dnr hipaa_acknowledgment plan_of_care].freeze
  KIND_LABELS = {
    "hospice_election"      => "Hospice Election of Benefit",
    "dnr"                   => "DNR / Code Status",
    "hipaa_acknowledgment"  => "HIPAA Acknowledgment",
    "plan_of_care"          => "Plan of Care"
  }.freeze

  # Forms required from every patient before care fully proceeds. Captured
  # during the admission visit by the Admission RN. DNR is excluded — it's a
  # separate clinical directive (flips code_status), not an admission consent.
  REQUIRED_KINDS = %w[hospice_election hipaa_acknowledgment plan_of_care].freeze

  # Required kinds this patient has not signed yet, in canonical order.
  def self.outstanding_required_for(patient)
    signed = patient.consent_forms.pluck(:kind).uniq
    REQUIRED_KINDS - signed
  end

  # Patient = the patient themselves. Everything else means a
  # representative is signing on the patient's behalf — relationship
  # + authority columns capture the why so a CMS auditor can tell
  # at a glance whether the surrogate had standing to sign.
  SIGNER_ROLES = %w[
    patient spouse son daughter parent sibling
    healthcare_proxy poa legal_guardian other_family
  ].freeze

  # Relationship roles a representative can pick (patient excluded — that's the
  # separate "The patient" path). [label, value] for a select.
  REPRESENTATIVE_ROLE_OPTIONS = [
    [ "Spouse", "spouse" ], [ "Son", "son" ], [ "Daughter", "daughter" ],
    [ "Parent", "parent" ], [ "Sibling", "sibling" ], [ "Other family", "other_family" ],
    [ "Healthcare proxy", "healthcare_proxy" ], [ "Power of attorney", "poa" ],
    [ "Legal guardian", "legal_guardian" ]
  ].freeze

  # Selectable reasons a representative has standing to sign (CMS wants a
  # documented basis). The stored value is the descriptive text itself.
  AUTHORITY_OPTIONS = [
    "Healthcare proxy / medical power of attorney on file",
    "Durable power of attorney on file",
    "Legal guardian or conservator",
    "Next of kin — patient is unable to sign",
    "Patient is present but physically unable to sign",
    "Other (documented in the patient's chart)"
  ].freeze

  # Map a free-text family relationship to a canonical signer_role.
  def self.role_for_relationship(rel)
    r = rel.to_s.strip.downcase
    (SIGNER_ROLES - [ "patient" ]).include?(r) ? r : "other_family"
  end

  validates :kind,        inclusion: { in: KINDS }
  validates :signer_role, inclusion: { in: SIGNER_ROLES }
  validates :signer_name, presence: true, length: { minimum: 2, maximum: 200 }
  validates :signer_authority, presence: true, if: -> { !signed_by_patient? }
  validates :signed_at, presence: true

  before_validation :default_signed_at, :stamp_agency

  scope :recent_first, -> { order(signed_at: :desc) }

  def signed_by_patient?
    signer_role == "patient"
  end

  def kind_label
    KIND_LABELS[kind] || kind.to_s.tr("_", " ").titleize
  end

  def signer_label
    return signer_name if signed_by_patient?
    rel = signer_relationship.presence || signer_role.tr("_", " ").titleize
    "#{signer_name} (#{rel})"
  end

  # ── Consent copy (single source of truth) ──────────────────────────
  # ATTESTATIONS is the exact text the signer attests to (snapshotted into
  # form_content at signing). RATIONALES is the plain-language "why this is
  # required" shown before signing. `%{agency}` is filled with the agency's
  # name so the document names who the care is from / whose notice it is.

  ATTESTATIONS = {
    "hospice_election" =>
      "I elect to receive hospice care from %{agency} under the Medicare/Medicaid Hospice Benefit. " \
      "I understand that hospice care is palliative (comfort-focused) rather than curative, and that by " \
      "electing this benefit I choose to waive Medicare/Medicaid coverage for treatments intended to cure my " \
      "terminal illness (comfort care and care unrelated to the terminal illness remain covered). %{agency} will " \
      "provide the nursing, physician oversight, medications, medical equipment, supplies, and social-work and " \
      "spiritual support related to my terminal condition. I understand I may revoke this election and return to " \
      "standard curative coverage at any time by notifying %{agency}.",
    "dnr" =>
      "I direct that, in the event my heart stops or I stop breathing, no cardiopulmonary resuscitation (CPR) be " \
      "attempted. Comfort-focused care will continue at all times. I understand this directive governs %{agency}'s " \
      "care of me and that I may revoke it at any time by notifying the hospice team.",
    "hipaa_acknowledgment" =>
      "I acknowledge that I have received %{agency}'s Notice of Privacy Practices, which describes how my protected " \
      "health information may be used and disclosed for treatment, payment, and health-care operations, and my " \
      "rights regarding that information.",
    "plan_of_care" =>
      "I have reviewed the hospice plan of care developed for me by %{agency}'s interdisciplinary team (nurse, " \
      "physician, social worker, and chaplain) and I agree to participate in the plan as described. I understand the " \
      "plan will be reviewed and updated as my needs change."
  }.freeze

  RATIONALES = {
    "hospice_election" =>
      "Federal law (the Medicare Hospice Benefit) requires a signed election before hospice care can begin. It " \
      "confirms you understand hospice is comfort-focused and that you can change your mind at any time. Without it, " \
      "%{agency} cannot provide or bill for the benefit.",
    "dnr" =>
      "This records your wishes about CPR so the care team and emergency responders honor them. It is entirely your " \
      "choice, can be changed at any time, and does not reduce any other comfort care you receive.",
    "hipaa_acknowledgment" =>
      "HIPAA requires %{agency} to give you its privacy notice and to document that you received it. Signing only " \
      "confirms you received the notice — it does not waive any of your privacy rights.",
    "plan_of_care" =>
      "Medicare requires that the patient or representative take part in the plan of care. Your agreement confirms " \
      "the team's plan reflects your goals and that you were part of the decisions."
  }.freeze

  # The agency's name, UPPERCASED, for the consent copy (falls back when blank).
  def self.agency_name(agency)
    raw = (agency.respond_to?(:name) ? agency.name : agency).to_s.strip
    (raw.presence || "the hospice agency").upcase
  end

  # Plain-text variants — used for the snapshot stored in form_content.
  def self.attestation_for(kind, agency: nil)
    interpolate_agency(ATTESTATIONS[kind.to_s], agency)
  end

  def self.rationale_for(kind, agency: nil)
    interpolate_agency(RATIONALES[kind.to_s], agency)
  end

  # HTML variants — the agency name rendered bold + uppercase for display.
  def self.attestation_html_for(kind, agency: nil)
    interpolate_agency_html(ATTESTATIONS[kind.to_s], agency)
  end

  def self.rationale_html_for(kind, agency: nil)
    interpolate_agency_html(RATIONALES[kind.to_s], agency)
  end

  def self.interpolate_agency(text, agency)
    return "" if text.blank?
    text.gsub("%{agency}", agency_name(agency))
  end

  # `text` is our own trusted copy (no HTML); only the agency name is escaped.
  def self.interpolate_agency_html(text, agency)
    return "".html_safe if text.blank?
    name = ERB::Util.html_escape(agency_name(agency))
    text.gsub("%{agency}", "<strong>#{name}</strong>").html_safe
  end

  # Render a stored snapshot (form_content) with the agency name bolded.
  # Everything is escaped first, so arbitrary stored text stays inert.
  def self.snapshot_html(text, agency)
    return "".html_safe if text.blank?
    esc  = ERB::Util.html_escape(text)
    name = ERB::Util.html_escape(agency_name(agency))
    esc.gsub(name, "<strong>#{name}</strong>").html_safe
  end

  private

  def default_signed_at = self.signed_at ||= Time.current

  def stamp_agency
    self.agency_id ||= patient&.agency_id
  end
end
