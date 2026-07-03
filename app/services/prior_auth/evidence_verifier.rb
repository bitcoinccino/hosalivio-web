require "set"

module PriorAuth
  # Stage-3 grounding gate (see docs/prior-auth-slice.md). Confirms an
  # LLM-claimed evidence quote actually appears on the cited source page — pure
  # Ruby, no network or model call. Anything unverifiable comes back :unverified
  # and MUST never render as a met ✓. This is the trust boundary that makes a
  # prior-auth recommendation defensible: every green check traces to verbatim
  # source text a human can click to.
  #
  #   evidence — { "doc_id" =>, "page" =>, "quote" => }  (string or symbol keys)
  #   source   — anything responding to #page(doc_id, page) -> String | nil
  #              (EvidenceCorpus in tests; DocumentText later)
  class EvidenceVerifier
    # Shorter quotes are too weak to trust (e.g. "yes", a bare date). Normalized
    # length, so punctuation/whitespace don't inflate it.
    MIN_QUOTE_LEN   = 12
    # Token-overlap ratio for a fuzzy match, to tolerate OCR / whitespace / a
    # single word of drift without accepting a scattered coincidental match.
    FUZZY_THRESHOLD = 0.9

    Result = Struct.new(:status, :score, :page_found, keyword_init: true) do
      def verified? = status == :verified
    end

    def self.verify(evidence, source)
      new(evidence, source).verify
    end

    # Batch helper — [{ evidence:, result: }, ...].
    def self.verify_all(evidences, source)
      Array(evidences).map { |e| { evidence: e, result: verify(e, source) } }
    end

    # Normalize for comparison: lowercase, punctuation → space, collapse runs of
    # whitespace. So "E.S.I. #3 —" and "esi 3" compare equal.
    def self.normalize(str)
      str.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").gsub(/\s+/, " ").strip
    end

    def initialize(evidence, source)
      @evidence = evidence || {}
      @source   = source
      @doc_id   = fetch(:doc_id)
      @page     = fetch(:page)
      @quote    = fetch(:quote).to_s
    end

    def verify
      text = @source&.page(@doc_id, @page)
      return result(:unverified, 0.0, false) if text.to_s.strip.empty?

      needle = self.class.normalize(@quote)
      return result(:unverified, 0.0, true) if needle.length < MIN_QUOTE_LEN

      haystack = self.class.normalize(text)
      return result(:verified, 1.0, true) if haystack.include?(needle)

      score  = best_window_overlap(needle, haystack)
      status = score >= FUZZY_THRESHOLD ? :verified : :unverified
      result(status, score.round(3), true)
    end

    private

    def fetch(key)
      v = @evidence[key.to_s]
      v.nil? ? @evidence[key.to_sym] : v
    end

    def result(status, score, page_found)
      Result.new(status: status, score: score, page_found: page_found)
    end

    # Best contiguous-window token overlap of the needle within the haystack.
    # Contiguity (a sliding window the length of the quote) is what keeps a fuzzy
    # match honest — it won't accept the quote's words scattered across the page.
    def best_window_overlap(needle, haystack)
      needle_tokens = needle.split
      page_tokens   = haystack.split
      size = needle_tokens.size
      return 0.0 if size.zero? || page_tokens.size < size

      needle_set = needle_tokens.to_set
      best = 0.0
      (0..(page_tokens.size - size)).each do |i|
        hits    = page_tokens[i, size].count { |w| needle_set.include?(w) }
        overlap = hits.to_f / size
        best = overlap if overlap > best
        break if best >= 1.0
      end
      best
    end
  end
end
