# Audit row written each time a clinician applies their e-signature
# to something in the chart. Polymorphic so PreAdmitEval, Visit, and
# any future signable record (late-entry notes, addendums) can share
# the table — CMS audit queries become a single `where(signable: …)`.
#
# `document_hash` snapshots the signed payload at signing time so an
# auditor can prove the underlying record wasn't mutated after the
# signature was applied. `intent_text` stores the exact copy the
# user accepted ("I certify that I have reviewed…") so future
# wording revisions don't rewrite history.
class Signature < ApplicationRecord
  belongs_to :user
  belongs_to :signable, polymorphic: true

  validates :document_hash,       presence: true
  validates :verification_method, presence: true
  validates :intent_text,         presence: true
  validates :signed_at,           presence: true

  before_validation :default_signed_at

  scope :recent_first, -> { order(signed_at: :desc) }

  def short_audit_line
    bits = []
    bits << signed_at.strftime("%b %-d, %Y · %-l:%M %p %Z")
    bits << verification_method.to_s.tr("_", " ")
    bits << "IP #{ip_address}" if ip_address.present?
    bits.join(" · ")
  end

  private

  def default_signed_at
    self.signed_at ||= Time.current
  end
end
