# Extracted, page-mapped plain text for a PatientDocument (Stage 0 of the
# prior-auth pipeline — see docs/prior-auth-slice.md). The text is what every
# later stage cites against, so it is stored per page and encrypted (PHI).
#
# Populated by PriorAuth::DocumentExtractor. `status` distinguishes a clean
# digital extract from a scan/image we couldn't read (needs_manual_review) —
# there is no OCR in the first slice, so we fail loud rather than pass empty.
class DocumentText < ApplicationRecord
  acts_as_tenant :agency

  belongs_to :agency
  belongs_to :patient_document

  encrypts :pages_json   # JSON: [{ "page" => Integer, "text" => String }]

  enum :status, { extracted: 0, needs_manual_review: 1 }, prefix: true

  # Parsed pages, always an array of { "page" =>, "text" => } hashes.
  def pages
    JSON.parse(pages_json.presence || "[]")
  rescue JSON::ParserError
    []
  end

  # Accepts [{ page:, text: }] (symbol or string keys); normalizes on write.
  def pages=(list)
    self.pages_json = Array(list).map do |p|
      { "page" => (p[:page] || p["page"]).to_i, "text" => (p[:text] || p["text"]).to_s }
    end.to_json
  end

  # Text of a single page, or nil. Lets a single DocumentText act as an
  # EvidenceVerifier source for its own document.
  def page(number)
    pages.find { |p| p["page"].to_i == number.to_i }&.fetch("text", nil)
  end

  # Flattened for EvidenceCorpus. doc_id is the PatientDocument id — the stable
  # handle the extractor/LLM cites.
  def segments
    pages.map { |p| { doc_id: patient_document_id, page: p["page"], text: p["text"] } }
  end
end
