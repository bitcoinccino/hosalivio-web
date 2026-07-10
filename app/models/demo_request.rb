# A "Book a demo" lead from the public landing page — a prospective partner
# (hospice owner / DON / admissions lead) who wants to see HosAlivio before
# committing to the full signup wizard. Not tenant-scoped: it's a top-of-funnel
# sales lead, not tied to an agency yet.
class DemoRequest < ApplicationRecord
  EHR_OPTIONS = [
    "Epic",
    "Oracle Health (Cerner)",
    "Homecare Homebase",
    "WellSky",
    "MatrixCare",
    "PointClickCare",
    "Netsmart",
    "Other / None"
  ].freeze

  REFERRAL_SOURCES = [
    "Search engine",
    "Referral or word of mouth",
    "Conference or event",
    "Social media",
    "Other"
  ].freeze

  validates :first_name, presence: true
  validates :last_name,  presence: true
  validates :work_email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :primary_ehr,     inclusion: { in: EHR_OPTIONS },      allow_blank: true
  validates :referral_source, inclusion: { in: REFERRAL_SOURCES }, allow_blank: true

  def full_name
    "#{first_name} #{last_name}".strip
  end

  # What to show for "how did you hear" — the free-text when they picked Other.
  def referral_display
    referral_source == "Other" ? referral_other.presence : referral_source.presence
  end
end
