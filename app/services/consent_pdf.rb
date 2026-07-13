# Renders a signed ConsentForm as a downloadable PDF (Prawn, pure Ruby — no
# external binaries, so it works on any host and downloads reliably on phones
# where browser print-to-PDF does not). Mirrors the consent show page: agency,
# patient, attestation, signer, signature image, and the audit hash.
class ConsentPdf
  GREY = "6B665F"
  INK  = "1D1C1A"

  def initialize(consent)
    @c       = consent
    @patient = consent.patient
    @agency  = consent.agency
    @sig     = consent.signatures.order(created_at: :desc).first
  end

  def filename
    "consent-#{@c.kind}-#{@patient.full_name.to_s.parameterize}.pdf"
  end

  def render
    Prawn::Fonts::AFM.hide_m17n_warning = true   # we sanitize text in #clean
    Prawn::Document.new(page_size: "LETTER", margin: 54) do |pdf|
      pdf.text clean(@agency&.name).upcase, size: 14, style: :bold, color: INK
      pdf.text "SIGNED CONSENT", size: 8, style: :bold, color: GREY
      pdf.move_down 2
      pdf.text clean(@c.kind_label), size: 18, color: INK
      pdf.move_down 6
      pdf.stroke_color GREY
      pdf.stroke_horizontal_rule
      pdf.move_down 14

      heading(pdf, "PATIENT")
      pdf.text "#{clean(@patient.full_name)}   •   MRN #{clean(@patient.mrn)}", size: 11, color: INK
      pdf.move_down 14

      heading(pdf, "ATTESTATION")
      pdf.text clean(@c.form_content), size: 10, leading: 3, color: INK, align: :justify
      pdf.move_down 14

      heading(pdf, "SIGNER")
      pdf.text clean(@c.signer_label), size: 11, color: INK
      pdf.text(@c.signed_by_patient? ? "Signed by the patient" : "Signed by a representative", size: 9, color: GREY)
      if @c.signer_authority.present?
        pdf.text "Authority to sign: #{clean(@c.signer_authority)}", size: 9, color: GREY
      end
      pdf.move_down 4
      pdf.text "Signed #{@c.signed_at.strftime('%B %-d, %Y at %-l:%M %p')}", size: 9, color: GREY
      pdf.text "Witnessed by #{clean(@c.witnessed_by&.full_name)}", size: 9, color: GREY
      pdf.move_down 14

      if @c.signature_image.attached?
        heading(pdf, "SIGNATURE")
        begin
          pdf.image StringIO.new(@c.signature_image.download), height: 60, position: :left
        rescue StandardError
          pdf.text "[signature image unavailable]", size: 9, color: GREY
        end
        pdf.move_down 14
      end

      if @sig
        pdf.stroke_horizontal_rule
        pdf.move_down 8
        heading(pdf, "AUDIT")
        pdf.text clean(@sig.short_audit_line), size: 8, color: GREY
        if @sig.document_hash.present?
          pdf.move_down 2
          pdf.text "SHA-256: #{@sig.document_hash}", size: 7, color: GREY
        end
      end
    end.render
  end

  private

  def heading(pdf, text)
    pdf.text text, size: 8, style: :bold, color: GREY
    pdf.move_down 3
  end

  # Prawn's built-in fonts are WinAnsi; swap the few typographic characters our
  # copy uses for ASCII so rendering never raises on an unencodable glyph.
  def clean(str)
    str.to_s
       .gsub(/[–—]/, "-")
       .gsub(/[‘’]/, "'")
       .gsub(/[“”]/, '"')
  end
end
