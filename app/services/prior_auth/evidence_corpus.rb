module PriorAuth
  # Minimal page-lookup source for EvidenceVerifier. Wraps a flat list of
  # { doc_id:, page:, text: } segments — the shape DocumentText#pages will expose
  # once Stage 0 lands, so the verifier never depends on the AR model directly.
  # Page keys are compared as integers so 7 and "7" resolve the same.
  class EvidenceCorpus
    def initialize(segments = [])
      @index = {}
      Array(segments).each do |seg|
        @index[key(fetch(seg, :doc_id), fetch(seg, :page))] = fetch(seg, :text).to_s
      end
    end

    # Build a corpus over one or more DocumentText records (each contributes its
    # #segments), so a review's extracted documents feed EvidenceVerifier directly.
    def self.from_document_texts(document_texts)
      new(Array(document_texts).flat_map(&:segments))
    end

    # -> String | nil
    def page(doc_id, page)
      @index[key(doc_id, page)]
    end

    private

    def key(doc_id, page)
      [ doc_id.to_s, page.to_i ]
    end

    def fetch(hash, k)
      v = hash[k.to_s]
      v.nil? ? hash[k.to_sym] : v
    end
  end
end
