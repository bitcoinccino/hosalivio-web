require "test_helper"

class PriorAuth::CriterionExtractorTest < ActiveSupport::TestCase
  setup do
    @policy = CoveragePolicy.create!(title: "Test LCD", payer: "medicare", source_type: "lcd",
                                     document_id: "L34538")
    @c_pps = @policy.criteria.create!(label: "PPS <= 70%",  position: 0, keywords: %w[pps])
    @c_adl = @policy.criteria.create!(label: ">= 3 ADLs",   position: 1)
    @c_dec = @policy.criteria.create!(label: "decline",     position: 2)

    @corpus = PriorAuth::EvidenceCorpus.new([
      { doc_id: "hp", page: 1,
        text: "Palliative Performance Scale is 60 percent. Dependent in bathing, dressing, and transfer." }
    ])
    @ext = PriorAuth::CriterionExtractor.new(@policy, [])
  end

  test "reconcile: a grounded 'met' stays met and verified" do
    findings = [ {
      "criterion_id" => @c_pps.id, "verdict" => "met", "rationale" => "PPS 60%",
      "evidence" => { "doc_id" => "hp", "page" => 1, "quote" => "Palliative Performance Scale is 60 percent" }
    } ]
    r = @ext.reconcile(findings, @corpus).first
    assert_equal @c_pps.id, r.criterion_id
    assert_equal "met", r.verdict
    assert r.verified
    assert r.met?
  end

  test "reconcile: a 'met' whose quote can't be grounded is downgraded to uncertain" do
    findings = [ {
      "criterion_id" => @c_pps.id, "verdict" => "met",
      "evidence" => { "doc_id" => "hp", "page" => 1, "quote" => "patient walks two miles daily unassisted" }
    } ]
    r = @ext.reconcile(findings, @corpus).first
    assert_equal "uncertain", r.verdict, "the trust gate downgrades an ungrounded met"
    assert_not r.verified
    assert_not r.met?
    assert r.evidence, "the unverified claim is kept for reviewer context, flagged verified=false"
  end

  test "reconcile: every criterion gets a result; a missing finding is a documented gap" do
    findings = [ {
      "criterion_id" => @c_pps.id, "verdict" => "met",
      "evidence" => { "doc_id" => "hp", "page" => 1, "quote" => "Palliative Performance Scale is 60 percent" }
    } ]
    results = @ext.reconcile(findings, @corpus)
    assert_equal [ @c_pps.id, @c_adl.id, @c_dec.id ], results.map(&:criterion_id), "ordered by criteria position"
    gap = results.last
    assert_equal "not_documented", gap.verdict
    assert gap.gap?
    assert_nil gap.evidence
  end

  test "reconcile: an out-of-range verdict is normalized to uncertain" do
    findings = [ { "criterion_id" => @c_dec.id, "verdict" => "definitely" } ]
    assert_equal "uncertain", @ext.reconcile(findings, @corpus).find { |r| r.criterion_id == @c_dec.id }.verdict
  end

  test "build_prompt includes each criterion id and page-marked document text" do
    ext = PriorAuth::CriterionExtractor.new(@policy, [ FakeDocText.new("hp", [ { page: 1, text: "PPS 60%" } ]) ])
    _system, user = ext.build_prompt
    assert_includes user, "id=#{@c_pps.id}"
    assert_includes user, "[doc=hp page=1]"
    assert_includes user, "PPS 60%"
  end

  test "call is dormant without an API key: every criterion comes back not_documented" do
    results = PriorAuth::CriterionExtractor.call(policy: @policy, document_texts: [])
    assert_equal 3, results.size
    assert results.all? { |r| r.verdict == "not_documented" }
  end

  test "HosalivioBrain.extract_json tolerates bare, fenced, and prose-wrapped JSON" do
    assert_equal([ 1, 2 ], HosalivioBrain.extract_json("[1, 2]"))
    assert_equal({ "a" => 1 }, HosalivioBrain.extract_json("```json\n{\"a\": 1}\n```"))
    assert_equal({ "a" => 1 }, HosalivioBrain.extract_json("Here you go: {\"a\": 1} — done"))
    assert_nil HosalivioBrain.extract_json("no json here")
    assert_nil HosalivioBrain.extract_json("")
  end

  # Minimal stand-in with the #segments duck type EvidenceCorpus expects.
  class FakeDocText
    def initialize(doc_id, pages)
      @doc_id = doc_id
      @pages  = pages
    end

    def segments
      @pages.map { |p| { doc_id: @doc_id, page: p[:page], text: p[:text] } }
    end
  end
end
