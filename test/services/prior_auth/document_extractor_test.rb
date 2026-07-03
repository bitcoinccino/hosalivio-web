require "test_helper"

class PriorAuth::DocumentExtractorTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @patient = in_tenant(@agency) { create_patient(agency: @agency) }
  end

  # ── helpers ─────────────────────────────────────────────────────────
  # A minimal but valid single-page uncompressed PDF with the given text.
  # Offsets are computed so PDF::Reader parses it without xref recovery.
  def minimal_pdf(text)
    bodies = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>"
    ]
    stream = "BT /F1 24 Tf 72 720 Td (#{text}) Tj ET"
    bodies << "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
    bodies << "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"

    out = +"%PDF-1.4\n"
    offsets = []
    bodies.each_with_index do |body, i|
      offsets << out.bytesize
      out << "#{i + 1} 0 obj\n#{body}\nendobj\n"
    end
    xref_pos = out.bytesize
    out << "xref\n0 #{bodies.size + 1}\n0000000000 65535 f \n"
    offsets.each { |o| out << format("%010d 00000 n \n", o) }
    out << "trailer\n<< /Size #{bodies.size + 1} /Root 1 0 R >>\nstartxref\n#{xref_pos}\n%%EOF\n"
    out
  end

  def document(io:, content_type:, filename:)
    in_tenant(@agency) do
      doc = PatientDocument.new(agency: @agency, patient: @patient, title: "H&P")
      doc.file.attach(io: io, filename: filename, content_type: content_type)
      doc.save!
      doc
    end
  end

  def pdf_document(text)
    document(io: StringIO.new(minimal_pdf(text)), content_type: "application/pdf", filename: "hp.pdf")
  end

  # ── tests ───────────────────────────────────────────────────────────
  test "extracts a digital PDF into page-mapped text, then verifies a quote against it" do
    doc = pdf_document("The patient completed 18 physical therapy sessions")

    dt = in_tenant(@agency) { PriorAuth::DocumentExtractor.call(doc) }

    assert dt.status_extracted?
    assert_equal doc.id, dt.patient_document_id
    assert_includes dt.page(1).to_s, "18 physical therapy sessions"

    # Stage 0 → Stage 3: the extracted text is a valid EvidenceVerifier source.
    corpus = PriorAuth::EvidenceCorpus.from_document_texts([ dt ])
    result = PriorAuth::EvidenceVerifier.verify(
      { doc_id: doc.id, page: 1, quote: "18 physical therapy sessions" }, corpus
    )
    assert result.verified?
  end

  test "a non-PDF document is stored as needs_manual_review (no OCR in slice 1)" do
    doc = document(io: StringIO.new("iVBORimagebytes"), content_type: "image/png", filename: "scan.png")
    dt  = in_tenant(@agency) { PriorAuth::DocumentExtractor.call(doc) }
    assert dt.status_needs_manual_review?
  end

  test "persist marks an empty or too-short extraction as needs_manual_review" do
    doc = pdf_document("irrelevant") # only persist() is exercised here
    ext = PriorAuth::DocumentExtractor.new(doc)

    empty = in_tenant(@agency) { ext.persist([]) }
    assert empty.status_needs_manual_review?

    blank = in_tenant(@agency) { ext.persist([ { page: 1, text: "   " } ]) }
    assert blank.status_needs_manual_review?

    real = in_tenant(@agency) { ext.persist([ { page: 1, text: "A sufficiently long line of real clinical text." } ]) }
    assert real.status_extracted?
  end

  test "re-extraction updates the same DocumentText in place (idempotent)" do
    doc = pdf_document("The patient completed 18 physical therapy sessions")
    in_tenant(@agency) do
      first  = PriorAuth::DocumentExtractor.call(doc)
      second = PriorAuth::DocumentExtractor.call(doc)
      assert_equal first.id, second.id
      assert_equal 1, DocumentText.where(patient_document_id: doc.id).count
    end
  end

  test "pages_json is encrypted at rest" do
    doc = pdf_document("The patient completed 18 physical therapy sessions")
    dt  = in_tenant(@agency) { PriorAuth::DocumentExtractor.call(doc) }
    raw = DocumentText.connection.select_value(
      "SELECT pages_json FROM document_texts WHERE id = #{DocumentText.connection.quote(dt.id)}"
    )
    refute_includes raw.to_s, "physical therapy", "the stored column must be ciphertext"
  end

  test "DocumentText#page and #segments expose the parsed pages" do
    doc = pdf_document("x")
    dt = in_tenant(@agency) do
      DocumentText.create!(agency: @agency, patient_document: doc, status: :extracted,
                           pages: [ { page: 1, text: "page one" }, { page: 2, text: "page two" } ])
    end
    assert_equal "page two", dt.page(2)
    assert_nil dt.page(3)
    segs = dt.segments
    assert_equal 2, segs.size
    assert_equal doc.id, segs.first[:doc_id]
  end
end
