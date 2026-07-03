require "pdf/reader"

module PriorAuth
  # Stage 0: turn a PatientDocument's attached file into page-mapped plain text
  # (a DocumentText). First slice = digital PDFs only; anything else, or a PDF
  # with no text layer (a scan), is stored as needs_manual_review rather than
  # passed through empty. No OCR yet (that's a later slice). Idempotent: one
  # DocumentText per document, re-extraction updates it in place.
  class DocumentExtractor
    # Below this many non-whitespace chars across all pages, treat it as a scan
    # we couldn't read (fail loud → manual review).
    MIN_TEXT_CHARS = 20
    PDF_TYPES = %w[application/pdf].freeze

    def self.call(patient_document)
      new(patient_document).call
    end

    def initialize(patient_document)
      @doc = patient_document
    end

    def call
      persist(read_pages)
    end

    # Pure: decide status from the page list and write the DocumentText. Split
    # out so the status logic is testable without a real PDF.
    def persist(pages)
      pages = Array(pages)
      total = pages.sum { |p| (p[:text] || p["text"]).to_s.gsub(/\s/, "").length }
      status = pages.any? && total >= MIN_TEXT_CHARS ? :extracted : :needs_manual_review

      dt = DocumentText.find_or_initialize_by(patient_document_id: @doc.id)
      dt.agency = @doc.agency
      dt.pages  = pages
      dt.status = status
      dt.save!
      dt
    end

    # [{ page:, text: }] from a PDF IO. Isolated + testable with a StringIO;
    # tolerates malformed/encrypted PDFs by returning [] (→ manual review).
    def self.pdf_pages(io)
      PDF::Reader.new(io).pages.map.with_index(1) do |page, i|
        { page: i, text: page.text.to_s.strip }
      end
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError,
           PDF::Reader::EncryptedPDFError => e
      Rails.logger.warn("[PriorAuth::DocumentExtractor] unreadable PDF: #{e.class}")
      []
    end

    private

    def read_pages
      return [] unless @doc.file.attached?
      return [] unless PDF_TYPES.include?(@doc.file.content_type.to_s)  # slice 1: PDF only

      @doc.file.blob.open { |tempfile| self.class.pdf_pages(tempfile) }
    rescue => e
      Rails.logger.warn("[PriorAuth::DocumentExtractor] #{e.class}: #{e.message}")
      []
    end
  end
end
