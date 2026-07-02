# Renders a PreAdmitEval as a conformant HL7 FHIR R4 *document* Bundle:
# a Composition (the admission-evaluation note) that ties together the Patient,
# the encounter, the terminal-diagnosis Condition, functional Observations, the
# CMS election/rights Consents, and (once certified) a Provenance carrying the
# certifying clinician's signature.
#
# This is the conformant replacement for PreAdmitEval#compile_vitas_payload's
# hand-rolled hash. It emits decrypted PHI by design (that is what an outbound
# EMR/referral push is), so callers must already be authorized + audited.
#
# Pure read, no side effects. Codes we can stand behind are coded (ICD-10-CM for
# the diagnosis, standard HL7 CodeSystems for statuses); anything we can't code
# cleanly falls back to CodeableConcept.text, which is valid FHIR.
module Fhir
  class PreAdmitEvalBundle
    FHIR_VERSION = "4.0.1".freeze

    MRN_SYSTEM       = "https://hosalivio.com/fhir/identifier/mrn".freeze
    AGENCY_SYSTEM    = "https://hosalivio.com/fhir/identifier/agency".freeze
    EVAL_SYSTEM      = "https://hosalivio.com/fhir/identifier/pre-admit-eval".freeze
    ICD10_SYSTEM     = "http://hl7.org/fhir/sid/icd-10-cm".freeze
    LOINC_SYSTEM     = "http://loinc.org".freeze
    BCP47_SYSTEM     = "urn:ietf:bcp:47".freeze

    def initialize(eval_record)
      @eval    = eval_record
      @patient = eval_record.patient
      @agency  = eval_record.agency
      # Stable urn:uuid fullUrls so intra-bundle references resolve.
      @url = Hash.new { |h, k| h[k] = "urn:uuid:#{SecureRandom.uuid}" }
    end

    def as_bundle
      # Build the referenced content first so the Composition can point at it.
      conditions   = condition_resources
      observations = observation_resources
      consents     = consent_resources
      medications  = medication_request_resources

      entries = []
      entries << bundle_entry(:composition, composition(conditions, observations, consents, medications))
      entries << bundle_entry(:patient, patient_resource)
      entries << bundle_entry(:organization, organization_resource)
      entries << bundle_entry(:encounter, encounter_resource)
      entries << bundle_entry(:practitioner, practitioner_resource) if practitioner?
      conditions.each   { |c| entries << bundle_entry_raw(c[:url], c[:resource]) }
      observations.each { |o| entries << bundle_entry_raw(o[:url], o[:resource]) }
      consents.each     { |c| entries << bundle_entry_raw(c[:url], c[:resource]) }
      medications.each  { |m| entries << bundle_entry_raw(m[:url], m[:resource]) }
      entries << bundle_entry(:provenance, provenance_resource) if certified?

      {
        resourceType: "Bundle",
        type:         "document",
        timestamp:    stamp(@eval.evaluated_at || @eval.created_at),
        identifier:   { system: EVAL_SYSTEM, value: @eval.id.to_s },
        entry:        entries
      }
    end

    private

    # ── Composition (the document's cover sheet) ──────────────────────
    def composition(conditions, observations, consents, medications)
      sections = []
      if conditions.any?
        sections << section("Terminal diagnosis", conditions.map { |c| ref(c[:url]) })
      end
      if observations.any?
        sections << section("Functional and cognitive status", observations.map { |o| ref(o[:url]) })
      end
      if consents.any?
        sections << section("Consents and elections", consents.map { |c| ref(c[:url]) })
      end
      if medications.any?
        sections << section("Comfort-kit medication orders", medications.map { |m| ref(m[:url]) })
      end

      {
        resourceType: "Composition",
        status:       composition_status,
        type: {
          coding: [ { system: LOINC_SYSTEM, code: "51848-0", display: "Evaluation note" } ],
          text:   "Hospice admission evaluation"
        },
        subject:   ref(@url[:patient]),
        encounter: ref(@url[:encounter]),
        date:      stamp(@eval.evaluated_at || @eval.created_at),
        author:    [ practitioner? ? ref(@url[:practitioner]) : ref(@url[:organization]) ],
        title:     "Hospice Admission Evaluation",
        custodian: ref(@url[:organization]),
        section:   sections
      }.compact
    end

    # draft → preliminary; final/certified/noe_filed → final; revoked → entered-in-error
    def composition_status
      return "entered-in-error" if @eval.status_revoked?
      @eval.status_draft? ? "preliminary" : "final"
    end

    # ── Patient ───────────────────────────────────────────────────────
    def patient_resource
      {
        resourceType: "Patient",
        identifier:   [ { system: MRN_SYSTEM, value: @patient.mrn.to_s } ],
        active:       true,
        name:         [ { use: "official", family: @patient.last_name.to_s, given: [ @patient.first_name.to_s ] } ],
        gender:       administrative_gender(@patient.gender),
        birthDate:    @patient.dob&.iso8601,
        address:      patient_address,
        telecom:      patient_telecom,
        communication: patient_communication
      }.compact
    end

    def patient_address
      line = [ @patient.address_line1, @patient.address_line2 ].map(&:presence).compact
      addr = {
        line:       line.presence,
        city:       @patient.city.presence,
        state:      @patient.state.presence,
        postalCode: @patient.zip.presence
      }.compact
      addr.empty? ? nil : [ addr ]
    end

    def patient_telecom
      tel = []
      tel << { system: "phone", value: @patient.phone } if @patient.phone.present?
      tel << { system: "email", value: @patient.email } if @patient.email.present?
      tel.presence
    end

    def patient_communication
      code = bcp47(@patient.preferred_language)
      return nil unless code
      [ { language: { coding: [ { system: BCP47_SYSTEM, code: code } ] }, preferred: true } ]
    end

    # ── Organization (the agency) ─────────────────────────────────────
    def organization_resource
      {
        resourceType: "Organization",
        identifier:   [ { system: AGENCY_SYSTEM, value: @agency.id.to_s } ],
        active:       true,
        name:         @agency.name
      }.compact
    end

    # ── Encounter (the eval visit) ────────────────────────────────────
    def encounter_resource
      {
        resourceType: "Encounter",
        status:       "finished",
        class:        { system: "http://terminology.hl7.org/CodeSystem/v3-ActCode", code: "HH", display: "home health" },
        type:         [ { text: @eval.visit&.visit_type.presence || "Hospice admission evaluation" } ],
        subject:      ref(@url[:patient]),
        participant:  (practitioner? ? [ { individual: ref(@url[:practitioner]) } ] : nil),
        period:       { start: stamp(@eval.evaluated_at || @eval.created_at) }.compact
      }.compact
    end

    # ── Practitioner (the evaluator) ──────────────────────────────────
    def practitioner?
      @eval.evaluator_name.present?
    end

    def practitioner_resource
      qual = @eval.evaluator_role.presence
      {
        resourceType: "Practitioner",
        identifier:   (@eval.evaluator_license.present? ? [ { system: "https://hosalivio.com/fhir/identifier/license", value: @eval.evaluator_license } ] : nil),
        active:       true,
        name:         [ { text: @eval.evaluator_name } ],
        qualification: (qual ? [ { code: { text: qual } } ] : nil)
      }.compact
    end

    # ── Condition (primary terminal diagnosis, ICD-10-CM coded) ───────
    def condition_resources
      return [] if @eval.primary_icd10.blank?
      resource = {
        resourceType:       "Condition",
        clinicalStatus:     { coding: [ { system: "http://terminology.hl7.org/CodeSystem/condition-clinical", code: "active" } ] },
        verificationStatus: { coding: [ { system: "http://terminology.hl7.org/CodeSystem/condition-ver-status", code: verification_code } ] },
        category:           [ { coding: [ { system: "http://terminology.hl7.org/CodeSystem/condition-category", code: "encounter-diagnosis", display: "Encounter Diagnosis" } ] } ],
        code: {
          coding: [ { system: ICD10_SYSTEM, code: @eval.primary_icd10, display: @eval.primary_icd10_description.presence }.compact ],
          text:   @eval.primary_icd10_description.presence || @eval.primary_icd10
        },
        subject:   ref(@url[:patient]),
        encounter: ref(@url[:encounter])
      }
      [ { url: "urn:uuid:#{SecureRandom.uuid}", resource: resource } ]
    end

    # confirmed once a clinician has certified; otherwise provisional.
    def verification_code
      certified? ? "confirmed" : "provisional"
    end

    # ── Observation (Palliative Performance Scale) ────────────────────
    def observation_resources
      score = @eval.pps_score
      return [] unless score
      resource = {
        resourceType: "Observation",
        status:       "final",
        code:         { text: "Palliative Performance Scale (PPS)" },
        subject:      ref(@url[:patient]),
        encounter:    ref(@url[:encounter]),
        valueQuantity: { value: score, unit: "%", system: "http://unitsofmeasure.org", code: "%" }
      }
      [ { url: "urn:uuid:#{SecureRandom.uuid}", resource: resource } ]
    end

    # ── Consent (CMS election of benefits + patient rights) ───────────
    CONSENTSCOPE_SYSTEM = "http://terminology.hl7.org/CodeSystem/consentscope".freeze
    PARTICIPATION_SYSTEM = "http://terminology.hl7.org/CodeSystem/v3-ParticipationType".freeze

    # Two consents, differentiated by the official consentscope value set (no
    # standard "hospice election" category code exists, so we do NOT invent one;
    # both keep the generic LOINC 59284-0 category). Each carries a provision.actor
    # linking the electing patient to THIS hospice Organization — the machine-
    # readable "electing this agency" signal.
    CONSENT_SPECS = {
      election: { scope: "treatment",      scope_display: "Treatment",       policy: "Medicare Hospice Election of Benefits" },
      rights:   { scope: "patient-privacy", scope_display: "Privacy Consent", policy: "Patient Rights reviewed" }
    }.freeze

    def consent_resources
      out = []
      out << consent(:election) if @eval.election_signed?
      out << consent(:rights)   if @eval.patient_rights_reviewed?
      out
    end

    def consent(type)
      spec = CONSENT_SPECS.fetch(type)
      resource = {
        resourceType: "Consent",
        status:       "active",
        scope:        { coding: [ { system: CONSENTSCOPE_SYSTEM, code: spec[:scope], display: spec[:scope_display] } ] },
        category:     [ { coding: [ { system: LOINC_SYSTEM, code: "59284-0", display: "Consent Document" } ] } ],
        patient:      ref(@url[:patient]),
        policyRule:   { text: spec[:policy] },
        provision:    { actor: [ {
          role:      { coding: [ { system: PARTICIPATION_SYSTEM, code: "PRF", display: "performer" } ] },
          reference: ref(@url[:organization])
        } ] }
      }
      { url: "urn:uuid:#{SecureRandom.uuid}", resource: resource }
    end

    # ── MedicationRequest (comfort-kit standing orders) ───────────────
    # Route abbreviation → readable label (SNOMED route codes deliberately not
    # fabricated; CodeableConcept.text is valid FHIR).
    ROUTE_LABELS = {
      "po"  => "by mouth (PO)",  "sl"  => "sublingual (SL)", "sc"  => "subcutaneous (SC)",
      "iv"  => "intravenous (IV)", "im" => "intramuscular (IM)", "pr" => "rectal (PR)",
      "top" => "topical",        "neb" => "nebulized",       "other" => "other route"
    }.freeze

    # active → active; hold → on-hold; dc → stopped; draft → draft.
    MED_STATUS = { "active" => "active", "hold" => "on-hold", "dc" => "stopped", "draft" => "draft" }.freeze

    def medication_request_resources
      @eval.comfort_kit_orders.map do |order|
        { url: "urn:uuid:#{SecureRandom.uuid}", resource: medication_request(order) }
      end
    end

    def medication_request(order)
      {
        resourceType:              "MedicationRequest",
        status:                    MED_STATUS.fetch(order.status.to_s, "unknown"),
        # A comfort-kit item stays a "proposal" until an MD authorizes it (active).
        intent:                    order.order_draft? ? "proposal" : "order",
        medicationCodeableConcept: medication_codeable_concept(order),
        subject:                   ref(@url[:patient]),
        encounter:                 ref(@url[:encounter]),
        authoredOn:                order.start_date&.iso8601,
        dosageInstruction:         [ dosage_instruction(order) ]
      }.compact
    end

    # RxNorm ingredient coding when we recognize the drug; always keep the raw
    # name as text so nothing is lost when we don't.
    def medication_codeable_concept(order)
      cc = { text: order.drug_name }
      if (rx = Coding::RxNorm.lookup(order.drug_name))
        cc[:coding] = [ { system: Coding::RxNorm::SYSTEM, code: rx.rxcui, display: rx.name } ]
      end
      cc
    end

    def dosage_instruction(order)
      dosage = {
        text:   dosage_text(order),
        timing: { code: { text: order.frequency } },
        route:  { text: ROUTE_LABELS.fetch(order.route.to_s, order.route.to_s) }
      }
      # asNeeded[x] is a choice: a coded indication implies PRN; otherwise the flag.
      if order.prn_indication.present?
        dosage[:asNeededCodeableConcept] = { text: order.prn_indication }
      else
        dosage[:asNeededBoolean] = order.prn
      end
      # Structured dose only when the string is a clean single value+unit; ranges,
      # concentrations ("20 mg/mL") and "1%" stay text-only in dosage[:text].
      if (dq = structured_dose(order.dose))
        dosage[:doseAndRate] = [ {
          type:         { coding: [ { system: "http://terminology.hl7.org/CodeSystem/dose-rate-type", code: "ordered", display: "Ordered" } ] },
          doseQuantity: dq
        } ]
      end
      dosage
    end

    # Whole-string "<number> <unit>" only. Returns a UCUM-coded quantity or nil.
    DOSE_RE = /\A(\d+(?:\.\d+)?)\s*(mg|mcg|g|ml|l|units?|tabs?|tablets?)\z/i
    UCUM = {
      "mg" => [ "mg", "mg" ], "mcg" => [ "mcg", "ug" ], "g" => [ "g", "g" ],
      "ml" => [ "mL", "mL" ], "l" => [ "L", "L" ],
      "unit" => [ "unit", "{unit}" ], "units" => [ "unit", "{unit}" ],
      "tab" => [ "tablet", "{tbl}" ], "tabs" => [ "tablet", "{tbl}" ],
      "tablet" => [ "tablet", "{tbl}" ], "tablets" => [ "tablet", "{tbl}" ]
    }.freeze

    def structured_dose(dose)
      m = DOSE_RE.match(dose.to_s.strip)
      return nil unless m
      unit, code = UCUM[m[2].downcase]
      value = m[1].include?(".") ? m[1].to_f : m[1].to_i
      { value: value, unit: unit, system: "http://unitsofmeasure.org", code: code }
    end

    def dosage_text(order)
      [
        order.dose,
        ROUTE_LABELS.fetch(order.route.to_s, order.route.to_s),
        order.frequency,
        (order.prn ? "PRN" : nil),
        (order.prn_indication.present? ? "for #{order.prn_indication}" : nil),
        order.instructions.presence
      ].compact.join(" ")
    end

    # ── Provenance (the certification signature) ──────────────────────
    def certified?
      @eval.certified_at.present?
    end

    def provenance_resource
      who = practitioner? ? ref(@url[:practitioner]) : { display: @eval.certified_by&.full_name.presence || "Certifying clinician" }
      {
        resourceType: "Provenance",
        target:       [ ref(@url[:composition]) ],
        recorded:     stamp(@eval.certified_at),
        agent:        [ {
          type: { coding: [ { system: "http://terminology.hl7.org/CodeSystem/provenance-participant-type", code: "author", display: "Author" } ] },
          who:  who
        } ],
        signature: [ {
          type: [ { system: "urn:iso-astm:E1762-95:2013", code: "1.2.840.10065.1.12.1.1", display: "Author's Signature" } ],
          when: stamp(@eval.certified_at),
          who:  who
        } ]
      }
    end

    # ── shared builders ───────────────────────────────────────────────
    def bundle_entry(key, resource)
      { fullUrl: @url[key], resource: resource }
    end

    def bundle_entry_raw(full_url, resource)
      { fullUrl: full_url, resource: resource }
    end

    def section(title, entries)
      { title: title, entry: entries }
    end

    def ref(full_url)
      { reference: full_url }
    end

    def stamp(time)
      (time || Time.current).iso8601
    end

    # Free-text gender → FHIR administrativeGender value set.
    def administrative_gender(raw)
      case raw.to_s.strip.downcase
      when "m", "male"      then "male"
      when "f", "female"    then "female"
      when "", nil          then "unknown"
      when "other", "x", "nonbinary", "non-binary" then "other"
      else "other"
      end
    end

    # App stores 2-letter ISO; FHIR wants BCP-47. Mirror the client mapping.
    def bcp47(code)
      case code.to_s.downcase
      when "en" then "en-US"
      when "es" then "es-ES"
      when "ht" then "ht"
      when "pt" then "pt-BR"
      else code.presence
      end
    end
  end
end
