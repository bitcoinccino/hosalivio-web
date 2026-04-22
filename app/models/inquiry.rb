class Inquiry < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail

  # PHI-light but still personal info. Encrypt at rest.
  encrypts :first_name
  encrypts :contact
  encrypts :zip,      deterministic: true   # deterministic so we can prefix-filter later
  encrypts :question

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
    InquiryProcessor.new(self).call
  end
end
