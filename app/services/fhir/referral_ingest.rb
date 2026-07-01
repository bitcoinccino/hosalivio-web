# Inbound direction: turn an incoming HL7 FHIR R4 referral Bundle into an
# Inquiry (a pre-admission lead) inside the receiving agency. The moment the
# Inquiry is created its normal fan-out runs — Mission Stage + the on-call
# admissions coordinator page — so an EMR referral lights up the same pipeline
# a landing-page callback does.
#
# Defensive by design: external bundles vary, so we read tolerantly (indifferent
# access, "first resource of type"), preserve the raw clinical diagnosis text in
# the inquiry question even when we can bucket it, and raise InvalidBundle with a
# clear reason when we can't build a usable lead.
module Fhir
  class ReferralIngest
    class InvalidBundle < StandardError; end

    # Reverse map: ICD-10-CM prefix → the public diagnosis bucket. Mirrors the
    # forward buckets in Inquiry::DIAGNOSIS_OPTIONS / the CMS hospice-LCD groups.
    ICD10_BUCKETS = [
      [ /\A(?:C|D0|B20)/i,     "Cancer" ],
      [ /\AI(?:0|1|2|3|4|5)/i, "Heart disease (CHF)" ],
      [ /\AJ4/i,               "Lung disease (COPD)" ],
      [ /\A(?:G30|F0)/i,       "Dementia or Alzheimer's" ],
      [ /\AI6/i,               "Stroke" ],
      [ /\A(?:G20|G12|G35)/i,  "Parkinson's or ALS" ],
      [ /\AN1[789]/i,          "Kidney (renal) failure" ],
      [ /\AK7/i,               "Liver disease" ],
      [ /\A(?:R62|R64|R53)/i,  "General decline / weakness" ]
    ].freeze

    def initialize(bundle, agency:)
      @bundle = bundle.is_a?(Hash) ? bundle.with_indifferent_access : {}
      @agency = agency
    end

    def call
      raise InvalidBundle, "payload is not a FHIR Bundle" unless @bundle[:resourceType] == "Bundle"

      patient = first_resource("Patient")
      raise InvalidBundle, "bundle has no Patient" if patient.nil?

      service   = first_resource("ServiceRequest")
      condition = first_resource("Condition")
      related   = first_resource("RelatedPerson")

      first_name, last_name = names(patient)
      phone, email = telecoms(patient, related)
      contact = phone.presence || email.presence
      raise InvalidBundle, "no phone or email contact point on Patient or RelatedPerson" if contact.blank?

      ActsAsTenant.with_tenant(@agency) do
        Inquiry.create!(
          agency:          @agency,
          is_general:      false,
          first_name:      first_name,
          last_name:       last_name,
          dob:             birth_date(patient),
          caregiver_phone: phone.presence,
          email:           email.presence,
          contact:         contact,
          zip:             postal_code(patient),
          diagnosis:       diagnosis_bucket(condition),
          requester_role:  requester_role(related),
          question:        referral_note(service, condition),
          source_prompt:   "fhir_referral",
          routed_to_role:  "admissions",
          status:          :new_lead
        )
      end
    end

    private

    def entries
      Array(@bundle[:entry])
    end

    def first_resource(type)
      entries.map { |e| e[:resource] }.compact.find { |r| r[:resourceType] == type }
    end

    def names(patient)
      name = Array(patient[:name]).find { |n| n[:use] == "official" } || Array(patient[:name]).first || {}
      given = Array(name[:given]).first
      # Fall back to splitting name.text if given/family are absent.
      if given.blank? && name[:text].present?
        parts = name[:text].to_s.split(/\s+/)
        given = parts.first
        family = parts[1..]&.join(" ")
      end
      [ given.to_s.strip.presence, (name[:family] || family).to_s.strip.presence ]
    end

    def telecoms(patient, related)
      points = Array(patient[:telecom]) + Array(related && related[:telecom])
      phone = points.find { |t| t[:system] == "phone" }&.dig(:value)
      email = points.find { |t| t[:system] == "email" }&.dig(:value)
      [ phone.to_s.strip, email.to_s.strip ]
    end

    def birth_date(patient)
      patient[:birthDate].to_s.strip.presence
    end

    def postal_code(patient)
      Array(patient[:address]).map { |a| a[:postalCode] }.compact.first.to_s.strip
    end

    # Map the referral's diagnosis to a public bucket. Prefer the ICD-10 code,
    # fall back to a keyword match on the text; nil if we can't be confident
    # (the raw description is still preserved in the question).
    def diagnosis_bucket(condition)
      return nil if condition.nil?
      code = Array(condition.dig(:code, :coding)).map { |c| c[:code] }.compact.first.to_s
      if (hit = ICD10_BUCKETS.find { |rx, _| rx.match?(code) })
        return hit.last
      end
      text = diagnosis_text(condition).to_s.downcase
      Inquiry::DIAGNOSIS_OPTIONS.find do |bucket|
        key = bucket.split(/[\s(]/).first.downcase   # "Cancer", "Heart", "Dementia", …
        key.length > 3 && text.include?(key)
      end
    end

    def diagnosis_text(condition)
      return nil if condition.nil?
      condition.dig(:code, :text).presence ||
        Array(condition.dig(:code, :coding)).map { |c| c[:display] }.compact.first
    end

    # A RelatedPerson submitter reads as family; a clinician-only referral leaves
    # the role blank rather than guessing a specific title.
    def requester_role(related)
      related.present? ? "Caregiver or Family Member" : nil
    end

    def referral_note(service, condition)
      parts = []
      dx = diagnosis_text(condition)
      code = Array(condition&.dig(:code, :coding)).map { |c| c[:code] }.compact.first if condition
      parts << "Referred diagnosis: #{dx}#{code ? " (#{code})" : ''}." if dx.present?
      Array(service && service[:note]).each { |n| parts << n[:text].to_s.strip if n[:text].present? }
      parts << "Inbound FHIR referral." if parts.empty?
      parts.join(" ")
    end
  end
end
