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

  # Friendly labels for the verification_method strings that the
  # different sign-off paths write. New action types just need a
  # row here; falls back to a humanized version of the key so
  # missing keys still render readably.
  VERIFICATION_LABELS = {
    "rn_route_to_md"                   => "Routed to MD",
    "md_certify"                       => "MD certification",
    "rn_visit_signoff"                 => "Visit sign-off",
    "visit_signoff"                    => "Visit sign-off",
    "drawn_inline_by_patient"          => "Patient signed in person",
    "drawn_inline_by_representative"   => "Representative signed in person",
    "registered_signature"             => "Registered signature",
    "drawn_inline"                     => "Drawn inline",
    "comfort_kit_authorize"            => "Comfort kit authorization",
    "prior_auth_signoff"               => "Prior-auth sign-off"
  }.freeze

  def verification_label
    VERIFICATION_LABELS[verification_method.to_s] ||
      verification_method.to_s.tr("_", " ").capitalize
  end

  # First 12 chars of the SHA256 document hash — like a git short
  # SHA. Enough entropy that two unrelated signatures wouldn't
  # collide on screen, short enough to fit in a chart line. Full
  # hash stays available in `document_hash` for an auditor.
  def short_hash
    document_hash.to_s[0, 12]
  end

  # One-liner shown under signature blocks ("Apr 30, 2026 · 2:14 PM
  # EDT · Visit sign-off · from this device · hash a3f9c2b18d4e").
  # IP gets formatted to something a non-engineer can parse —
  # localhost / IPv6 loopback collapse to "from this device",
  # anything else renders only the network portion (first three
  # octets) so a CMS auditor still sees IP context without us
  # flashing a full address on the chart. Hash is the security
  # fingerprint that lets an auditor confirm the signed payload
  # hasn't been tampered with after signing.
  def short_audit_line
    bits = []
    bits << signed_at.strftime("%b %-d, %Y · %-l:%M %p %Z")
    bits << verification_label
    bits << friendly_ip_label if ip_address.present?
    bits << "hash #{short_hash}" if document_hash.present?
    bits.compact.join(" · ")
  end

  def friendly_ip_label
    ip = ip_address.to_s
    return "from this device" if ip == "::1" || ip == "127.0.0.1" || ip.start_with?("::ffff:127.")
    return "private network"  if ip.start_with?("10.", "192.168.") || ip =~ /\A172\.(1[6-9]|2\d|3[01])\./
    return ip                  if ip.include?(":")              # IPv6 — leave intact, it's already opaque enough
    masked = ip.split(".").first(3).join(".") + ".x"
    "IP #{masked}"
  end

  private

  def default_signed_at
    self.signed_at ||= Time.current
  end
end
