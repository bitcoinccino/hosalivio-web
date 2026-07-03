require "test_helper"

class PriorAuth::EvidenceVerifierTest < ActiveSupport::TestCase
  # A short two-page corpus. doc "hp" p1 = H&P, doc "req" p1 = the request.
  def corpus
    PriorAuth::EvidenceCorpus.new([
      { doc_id: "hp",  page: 1, text: "History and Physical. The patient completed a nine month course of conservative therapy without relief. Physical therapy: 18 sessions with documented functional plateau. ODI score 44." },
      { doc_id: "hp",  page: 2, text: "MRI of the lumbar spine performed 10/28/2024 demonstrates L4-L5 stenosis." },
      { doc_id: "req", page: 1, text: "Prior authorization request for lumbar spinal fusion, provider NPI 1578671483." }
    ])
  end

  def verify(evidence)
    PriorAuth::EvidenceVerifier.verify(evidence, corpus)
  end

  test "an exact quote on the cited page verifies" do
    r = verify("doc_id" => "hp", "page" => 1, "quote" => "18 sessions with documented functional plateau")
    assert r.verified?
    assert_equal 1.0, r.score
    assert r.page_found
  end

  test "case / punctuation / whitespace differences still verify (normalized)" do
    r = verify("doc_id" => "hp", "page" => 1, "quote" => "ODI  SCORE   44.")
    assert r.verified?, "normalization should collapse case/space/punctuation"
  end

  test "a quote that isn't on the page is unverified" do
    r = verify("doc_id" => "hp", "page" => 1, "quote" => "patient received three epidural steroid injections")
    assert_not r.verified?
    assert r.page_found, "the page existed; the quote just wasn't in it"
  end

  test "a real quote cited to the WRONG page is unverified" do
    # This text is on hp p2, not p1.
    r = verify("doc_id" => "hp", "page" => 1, "quote" => "MRI of the lumbar spine performed 10 28 2024")
    assert_not r.verified?
  end

  test "an unknown doc id is unverified and reports page not found" do
    r = verify("doc_id" => "nope", "page" => 1, "quote" => "any text at all here")
    assert_not r.verified?
    assert_not r.page_found
  end

  test "a too-short quote is rejected as too weak to trust" do
    r = verify("doc_id" => "req", "page" => 1, "quote" => "fusion")
    assert_not r.verified?
    assert_equal 0.0, r.score
  end

  test "fuzzy: one word of drift over a long quote still verifies (>= 0.9)" do
    # source says "conservative therapy"; quote says "conservative treatment"
    r = verify("doc_id" => "hp", "page" => 1,
               "quote" => "patient completed a nine month course of conservative treatment without relief")
    assert r.verified?, "10/11 token overlap should clear the fuzzy threshold"
    assert_operator r.score, :>=, 0.9
    assert_operator r.score, :<, 1.0
  end

  test "fuzzy: two words of drift falls below threshold and is unverified" do
    r = verify("doc_id" => "hp", "page" => 1,
               "quote" => "patient completed a nine week course of aggressive treatment without relief")
    assert_not r.verified?
  end

  test "symbol keys work as well as string keys" do
    r = verify(doc_id: "hp", page: 1, quote: "18 sessions with documented functional plateau")
    assert r.verified?
  end

  test "nil evidence is handled and unverified" do
    assert_not PriorAuth::EvidenceVerifier.verify(nil, corpus).verified?
  end

  test "verify_all returns a result per evidence" do
    out = PriorAuth::EvidenceVerifier.verify_all(
      [ { doc_id: "hp", page: 1, quote: "ODI score 44" },
        { doc_id: "hp", page: 1, quote: "not present anywhere here" } ],
      corpus
    )
    assert_equal 2, out.size
    assert out[0][:result].verified?
    assert_not out[1][:result].verified?
  end
end
