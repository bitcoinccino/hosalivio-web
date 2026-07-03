module PriorAuth
  # Stage 2: criterion-anchored extraction (see docs/prior-auth-slice.md). Given a
  # CoveragePolicy and the patient's extracted DocumentTexts, it asks the model —
  # under a strict never-infer rule — for supporting evidence per criterion, then
  # pipes every claimed quote through Stage 3 (EvidenceVerifier). A "met" the model
  # cannot ground is downgraded to "uncertain": the trust gate. Returns one Result
  # per policy criterion (which feeds CriterionResult / the review later).
  #
  # The LLM call is isolated in #request_findings and dormant without an API key
  # (returns []). The scoring logic (#reconcile) is pure and fully tested.
  class CriterionExtractor
    MAX_TOKENS = 2000
    VERDICTS   = %w[met unmet not_documented uncertain].freeze

    SYSTEM = <<~PROMPT.freeze
      You are a medical-necessity reviewer checking a prior-authorization request
      against a coverage policy's criteria, using ONLY the supplied documents.

      Rules:
      - NEVER infer or assume. A criterion is "met" only on explicit documented evidence.
      - Quote evidence VERBATIM from the documents. Do not paraphrase. Do not invent.
      - Cite the exact doc id and page the quote came from.
      - If a criterion is not supported by any document, return verdict
        "not_documented" with evidence null. Do not guess.

      Output JSON ONLY — an array, one object per criterion you can speak to:
      [{ "criterion_id": "<id from CRITERIA>",
         "verdict": "met" | "unmet" | "not_documented" | "uncertain",
         "evidence": { "doc_id": "<id>", "page": <number>, "quote": "<verbatim>" } | null,
         "rationale": "<one short line, no inference>" }]
    PROMPT

    Result = Struct.new(:criterion_id, :label, :verdict, :verified, :evidence, :rationale, keyword_init: true) do
      def met?      = verdict.to_s == "met" && verified
      def gap?      = %w[unmet not_documented uncertain].include?(verdict.to_s)
    end

    def self.call(policy:, document_texts:)
      new(policy, document_texts).call
    end

    def initialize(policy, document_texts)
      @policy         = policy
      @document_texts = Array(document_texts)
    end

    def call
      corpus = EvidenceCorpus.from_document_texts(@document_texts)
      reconcile(request_findings, corpus)
    end

    # PURE: map raw model findings onto the policy's criteria (in order), verify
    # each cited quote, and apply the trust gate. Every criterion gets a result —
    # a criterion with no finding is a documented gap (not_documented).
    def reconcile(findings, corpus)
      by_id = Array(findings).each_with_object({}) do |f, h|
        id = fetch(f, :criterion_id).to_s
        h[id] = f unless id.empty?
      end
      @policy.criteria.map { |crit| result_for(crit, by_id[crit.id.to_s], corpus) }
    end

    # PURE: [system, user] prompt — criteria specs + page-marked document text.
    def build_prompt
      [ SYSTEM, user_prompt ]
    end

    private

    def result_for(criterion, finding, corpus)
      return not_documented(criterion) if finding.nil?

      verdict  = fetch(finding, :verdict).to_s
      verdict  = "uncertain" unless VERDICTS.include?(verdict)
      evidence = fetch(finding, :evidence)
      verified = evidence.is_a?(Hash) && EvidenceVerifier.verify(evidence, corpus).verified?
      # Trust gate: a "met" the model can't ground in the source is not "met".
      verdict  = "uncertain" if verdict == "met" && !verified

      Result.new(criterion_id: criterion.id, label: criterion.label, verdict: verdict,
                 verified: verified, evidence: evidence, rationale: fetch(finding, :rationale))
    end

    def not_documented(criterion)
      Result.new(criterion_id: criterion.id, label: criterion.label,
                 verdict: "not_documented", verified: false, evidence: nil, rationale: nil)
    end

    def request_findings
      system, user = build_prompt
      data = HosalivioBrain.complete_json(system: system, user: user, max_tokens: MAX_TOKENS)
      case data
      when Array then data
      when Hash  then Array(data["findings"] || data[:findings])
      else            []
      end
    end

    def user_prompt
      lines = @policy.criteria.map do |c|
        kw = Array(c.keywords).join(", ")
        "- id=#{c.id} | #{c.label}#{kw.empty? ? "" : " (keywords: #{kw})"}"
      end
      "POLICY: #{@policy.citation}\n\nCRITERIA:\n#{lines.join("\n")}\n\nDOCUMENTS:\n#{documents_text}"
    end

    def documents_text
      @document_texts.flat_map(&:segments).map do |seg|
        "[doc=#{seg[:doc_id]} page=#{seg[:page]}]\n#{seg[:text]}"
      end.join("\n\n")
    end

    def fetch(hash, key)
      return nil unless hash.is_a?(Hash)
      v = hash[key.to_s]
      v.nil? ? hash[key.to_sym] : v
    end
  end
end
