# Inbound direction: turn an incoming HL7 FHIR R4 referral Bundle into an
# Inquiry (a pre-admission lead) inside the receiving agency. The moment the
# Inquiry is created its normal fan-out runs — Mission Stage + the on-call
# admissions coordinator page.
#
# Per the FHIR→Inquiry data contract we map the R4 ServiceRequest (the R4
# successor to STU3 ReferralRequest): requester→referring_provider,
# code→requested_service, reasonCode→reason_for_referral, priority→urgency,
# authoredOn→referral_date, occurrence→desired_date, identifier→
# external_referral_id (dedup key), plus the Patient demographics + MRN. We do
# NOT create a Patient here — the MRN is captured on the lead and the coordinator
# matches-or-creates the chart at convert_to_patient time (human-in-the-loop).
#
# call returns a Result: an Inquiry (created or, on a re-sent referral, the
# existing duplicate), or a list of validation issues for the OperationOutcome.
module Fhir
  class ReferralIngest
    class InvalidBundle < StandardError; end

    Result = Struct.new(:inquiry, :issues, :duplicate, keyword_init: true) do
      def ok?        = issues.blank? && inquiry.present?
      def duplicate? = duplicate.present?
    end

    # Reverse map: ICD-10-CM prefix → the public diagnosis bucket.
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

      patient   = first_resource("Patient")
      service   = first_resource("ServiceRequest")
      condition = first_resource("Condition")
      related   = first_resource("RelatedPerson")

      issues = mvp_issues(patient, service, condition, related)
      return Result.new(issues: issues) if issues.any?

      ext_id = external_referral_id(service)
      if ext_id.present?
        existing = ActsAsTenant.with_tenant(@agency) { Inquiry.where(agency: @agency, external_referral_id: ext_id).first }
        return Result.new(inquiry: existing, duplicate: true) if existing
      end

      inquiry = ActsAsTenant.with_tenant(@agency) do
        Inquiry.create!(attributes(patient, service, condition, related, ext_id))
      end
      Result.new(inquiry: inquiry)
    end

    private

    def attributes(patient, service, condition, related, ext_id)
      first_name, last_name = names(patient)
      phone, email = telecoms(patient, related)
      {
        agency:              @agency,
        is_general:          false,
        first_name:          first_name,
        last_name:           last_name,
        dob:                 birth_date(patient),
        external_mrn:        mrn(patient),
        caregiver_phone:     phone.presence,
        email:               email.presence,
        contact:             phone.presence || email.presence,
        zip:                 postal_code(patient),
        diagnosis:           diagnosis_bucket(condition),
        requester_role:      requester_role(related),
        referring_provider:  referring_provider(service),
        requested_service:   requested_service(service),
        reason_for_referral: reason_for_referral(service, condition),
        urgency:             urgency(service),
        referral_date:       parse_time(service && service[:authoredOn]),
        desired_date:        desired_date(service),
        external_referral_id: ext_id,
        raw_fhir_payload:    @bundle.to_json,
        question:            referral_note(service, condition),
        source_prompt:       "fhir_referral",
        routed_to_role:      "admissions",
        status:              lead_status(service)
      }
    end

    # Graceful degradation: we reject only the one structural floor we cannot
    # build a lead without — a Patient resource. Everything else (provider,
    # reason/service, DOB, MRN, contact, priority, dates) degrades to nil and is
    # captured if present, to maximize top-of-funnel intake. Structural FHIR
    # validity is enforced upstream by the controller's schema check.
    def mvp_issues(patient, _service, _condition, _related)
      return [ issue("Bundle.entry.resource.ofType(Patient)", "A Patient resource is required.") ] if patient.nil?
      []
    end

    def issue(expression, message, code: "required")
      { expression: expression, message: message, code: code }
    end

    # ── resource lookup + reference resolution ────────────────────────
    def entries
      Array(@bundle[:entry])
    end

    def first_resource(type)
      entries.map { |e| e[:resource] }.compact.find { |r| r[:resourceType] == type }
    end

    # A Reference may be a bundle-local "urn:uuid:…" fullUrl or a "Type/id".
    def resolve_reference(reference)
      return nil if reference.blank?
      by_url = entries.find { |e| e[:fullUrl] == reference }
      return by_url[:resource] if by_url
      entries.map { |e| e[:resource] }.compact.find { |r| "#{r[:resourceType]}/#{r[:id]}" == reference }
    end

    # ── Patient mappers ───────────────────────────────────────────────
    def names(patient)
      name = Array(patient[:name]).find { |n| n[:use] == "official" } || Array(patient[:name]).first || {}
      given  = Array(name[:given]).first
      family = name[:family]
      if given.blank? && family.blank? && name[:text].present?
        parts  = name[:text].to_s.split(/\s+/)
        given  = parts.first
        family = parts[1..]&.join(" ")
      end
      [ given.to_s.strip.presence, family.to_s.strip.presence ]
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

    # Prefer a Medical Record Number identifier; fall back to a system hint, then first.
    def mrn(patient)
      ids = Array(patient[:identifier])
      mr = ids.find { |i| Array(i.dig(:type, :coding)).any? { |c| c[:code] == "MR" } } ||
           ids.find { |i| i[:system].to_s.downcase.include?("mrn") } ||
           ids.first
      mr && mr[:value].to_s.strip.presence
    end

    def requester_role(related)
      related.present? ? "Caregiver or Family Member" : nil
    end

    # ── ServiceRequest mappers ────────────────────────────────────────
    def referring_provider(service)
      return nil unless service
      ref     = service.dig(:requester, :reference)
      display = service.dig(:requester, :display)
      provider_name(resolve_reference(ref)) || display.to_s.strip.presence
    end

    def provider_name(resource)
      return nil if resource.nil?
      case resource[:resourceType]
      when "Organization"
        resource[:name].to_s.strip.presence
      when "Practitioner", "PractitionerRole"
        n = Array(resource[:name]).first || {}
        n[:text].to_s.strip.presence ||
          [ Array(n[:given]).join(" "), n[:family] ].map(&:presence).compact.join(" ").strip.presence
      end
    end

    def requested_service(service)
      return nil unless service
      service.dig(:code, :text).to_s.strip.presence ||
        coding_display(service.dig(:code, :coding)) ||
        Array(service[:orderDetail]).map { |o| o[:text].presence || coding_display(o[:coding]) }.compact.first
    end

    # Contract: prefer the internal clinical Condition; fall back to the
    # ServiceRequest.reasonCode / reasonReference so nothing is lost when no
    # Condition is present.
    def reason_for_referral(service, condition)
      dx = diagnosis_text(condition)
      return dx if dx.present?
      return nil unless service
      rc = Array(service[:reasonCode]).map { |c| c[:text].presence || coding_display(c[:coding]) }.compact.first
      rc.presence || Array(service[:reasonReference]).map { |r| r[:display] }.compact.first
    end

    def urgency(service)
      p = service && service[:priority].to_s.downcase
      Inquiry::URGENCY_LEVELS.include?(p) ? p : nil
    end

    def desired_date(service)
      return nil unless service
      parse_time(service[:occurrenceDateTime] || service.dig(:occurrencePeriod, :start))
    end

    def external_referral_id(service)
      return nil unless service
      Array(service[:identifier]).map { |i| i[:value] }.compact.first.to_s.strip.presence
    end

    # Revoked / entered-in-error orders are not live leads.
    def lead_status(service)
      %w[revoked entered-in-error].include?(service && service[:status].to_s) ? :dismissed : :new_lead
    end

    # ── Condition / shared helpers ────────────────────────────────────
    def diagnosis_bucket(condition)
      return nil if condition.nil?
      code = Array(condition.dig(:code, :coding)).map { |c| c[:code] }.compact.first.to_s
      if (hit = ICD10_BUCKETS.find { |rx, _| rx.match?(code) })
        return hit.last
      end
      text = diagnosis_text(condition).to_s.downcase
      Inquiry::DIAGNOSIS_OPTIONS.find do |bucket|
        key = bucket.split(/[\s(]/).first.downcase
        key.length > 3 && text.include?(key)
      end
    end

    def diagnosis_text(condition)
      return nil if condition.nil?
      condition.dig(:code, :text).presence || coding_display(condition.dig(:code, :coding))
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

    def coding_display(coding)
      Array(coding).map { |c| c[:display] }.compact.first.to_s.strip.presence
    end

    def parse_time(str)
      return nil if str.blank?
      Time.zone.parse(str.to_s)
    rescue ArgumentError
      nil
    end
  end
end
