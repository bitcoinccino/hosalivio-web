require "test_helper"

class CoveragePolicyTest < ActiveSupport::TestCase
  def policy(**attrs)
    CoveragePolicy.create!({ title: "Test Policy", payer: "medicare", source_type: "lcd" }.merge(attrs))
  end

  test "validations: title required, payer + source_type constrained" do
    assert_not CoveragePolicy.new(payer: "medicare", source_type: "lcd").valid?    # no title
    assert_not policy_invalid?(source_type: "guideline")
    assert_not policy_invalid?(payer: "aetna")   # slice 1 is Medicare-only
    assert policy(source_type: "ncd").persisted?
  end

  test "criteria are ordered by position" do
    p = policy
    p.criteria.create!(label: "second", position: 1)
    p.criteria.create!(label: "first",  position: 0)
    assert_equal %w[first second], p.criteria.pluck(:label)
  end

  test "for_hcpcs finds the active policy governing a procedure code" do
    p = policy(procedure_hcpcs: %w[Q5001 Q5002])
    assert_equal p, CoveragePolicy.for_hcpcs("q5001")   # case-insensitive
    assert_nil CoveragePolicy.for_hcpcs("99999")
    assert_nil CoveragePolicy.for_hcpcs("")
  end

  test "for_hcpcs ignores inactive policies" do
    policy(procedure_hcpcs: %w[Q5001], active: false)
    assert_nil CoveragePolicy.for_hcpcs("Q5001")
  end

  test "citation combines document id and title" do
    assert_equal "L34538 — Hospice Determining Terminal Status",
                 policy(document_id: "L34538", title: "Hospice Determining Terminal Status").citation
  end

  test "PolicyCriterion validates evidence_type and exposes an extraction spec" do
    p = policy
    assert_not p.criteria.new(label: "x", evidence_type: "vibes").valid?
    c = p.criteria.create!(label: "PPS <= 70%", evidence_type: "score", keywords: %w[pps])
    spec = c.to_extraction_spec
    assert_equal c.id, spec[:criterion_id]
    assert_equal "score", spec[:evidence_type]
    assert_equal %w[pps], spec[:keywords]
  end

  test "the prior-auth seed loads a real LCD as data and is idempotent" do
    path = Rails.root.join("db", "seeds_prior_auth.rb").to_s
    2.times { load path }   # running twice must not duplicate
    p = CoveragePolicy.find_by(document_id: "L34538")
    assert p, "seed created the L34538 policy"
    assert_equal 5, p.criteria.count
    assert_equal p, CoveragePolicy.for_hcpcs("Q5001")
  end

  private

  def policy_invalid?(**attrs)
    CoveragePolicy.new({ title: "T", payer: "medicare", source_type: "lcd" }.merge(attrs)).valid?
  end
end
