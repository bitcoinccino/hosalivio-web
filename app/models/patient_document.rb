# A supporting document attached to a patient's record — a signed form
# (Election of Benefits, DNR, POLST), a photo of paperwork, etc. MVP scope:
# store + download only. No AI reading/extraction.
class PatientDocument < ApplicationRecord
  acts_as_tenant :agency

  belongs_to :agency
  belongs_to :patient
  belongs_to :uploaded_by, class_name: "User", optional: true

  has_one_attached :file

  MAX_BYTES = 25.megabytes
  ALLOWED_TYPES = %w[
    application/pdf image/png image/jpeg image/heic image/heif image/webp
  ].freeze

  # Optional label for what kind of form this is (free-form for MVP).
  KIND_LABELS = {
    "election_of_benefits" => "Election of Benefits",
    "patient_rights"       => "Patient Rights",
    "general_consent"      => "General Consent",
    "proxy_poa"            => "Proxy / POA",
    "dnr"                  => "DNR",
    "polst"                => "POLST",
    "advance_directive"    => "Advance Directive",
    "financial_agreement"  => "Financial Agreement",
    "other"                => "Other"
  }.freeze

  validates :title, presence: true, length: { maximum: 200 }
  validate :file_attached_and_valid

  scope :newest_first, -> { order(created_at: :desc) }

  def image?      = file.attached? && file.content_type.to_s.start_with?("image/")
  def kind_label  = KIND_LABELS[kind] || kind.to_s.tr("_", " ").titleize.presence

  private

  def file_attached_and_valid
    unless file.attached?
      errors.add(:file, "is required")
      return
    end
    errors.add(:file, "must be a PDF or image") unless ALLOWED_TYPES.include?(file.content_type)
    errors.add(:file, "is too large (max 25 MB)") if file.blob && file.blob.byte_size > MAX_BYTES
  end
end
