# Prior-auth coverage policies — reference data (global, not tenant-scoped).
# Idempotent. Run standalone:
#   bin/rails runner 'load Rails.root.join("db", "seeds_prior_auth.rb").to_s'
#
# Seeds one REAL Medicare LCD (Hospice "Determining Terminal Status", L34538)
# expressed as data — a first, honest example that also demonstrates the generic
# policy/criteria model can represent the hospice determination the app already
# knows in Ruby (PreAdmitValidator / Cms::HospiceCoverage).
#
# NOTE: criterion wording below reflects genuine hospice-eligibility concepts but
# must be SME-verified against the live LCD text before any production reliance.

policy = CoveragePolicy.find_or_create_by!(document_id: "L34538") do |p|
  p.payer           = "medicare"
  p.source_type     = "lcd"
  p.title           = "Hospice Determining Terminal Status"
  p.url             = "https://www.cms.gov/medicare-coverage-database/view/lcd.aspx?lcdid=34538"
  p.procedure_hcpcs = %w[Q5001 Q5002]   # hospice care place-of-service HCPCS
  p.active          = true
end

criteria = [
  { label: "Physician certification of terminal illness (life expectancy <= 6 months)",
    evidence_type: "text",  keywords: %w[terminal prognosis certify certification life expectancy six months] },
  { label: "Palliative Performance Scale (PPS) <= 70%",
    evidence_type: "score", keywords: [ "pps", "palliative performance", "performance scale" ] },
  { label: "Dependence in >= 3 activities of daily living",
    evidence_type: "count", keywords: [ "adl", "activities of daily living", "bathing", "dressing", "transfer", "dependent" ] },
  { label: "Documented progressive clinical decline",
    evidence_type: "text",  keywords: %w[decline worsening progressive deterioration] },
  { label: "Documented nutritional decline / weight loss",
    evidence_type: "text",  keywords: [ "weight loss", "poor intake", "albumin", "cachexia", "nutrition" ] }
]

criteria.each_with_index do |c, i|
  pc = policy.criteria.find_or_initialize_by(label: c[:label])
  pc.position      = i
  pc.evidence_type = c[:evidence_type]
  pc.keywords      = c[:keywords]
  pc.save!
end

if defined?(Rails::Console) || $PROGRAM_NAME.end_with?("rails")
  puts "Seeded coverage policy #{policy.citation} with #{policy.criteria.count} criteria."
end
