require "test_helper"

module Fhir
  class PreAdmitEvalBundleTest < ActiveSupport::TestCase
    setup do
      @agency  = create_agency
      @rn      = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
      @patient = create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez")
      in_tenant(@agency) do
        @patient.update!(gender: "female", zip: "33101", phone: "305-555-0100",
                         email: "maria@example.com", preferred_language: "es")
      end
      @eval = in_tenant(@agency) do
        PreAdmitEval.create!(
          agency: @agency, patient: @patient, evaluator: @rn,
          evaluator_name: "Reggie RN", evaluator_role: "rn", evaluator_license: "RN12345",
          evaluated_at: Time.current, status: :certified, certified_at: Time.current, certified_by: @rn,
          raw_json: { "pre_admit_eval" => {
            "diagnosis" => {
              "primary_terminal_diagnosis" => { "icd10" => "C34.90", "description" => "Malignant neoplasm of lung" },
              "lcd_criteria_met" => [ "meets" ]
            },
            "functional_decline" => { "pps" => { "score" => 40 } },
            "general" => { "election_of_benefits_signed" => true, "patient_rights_reviewed" => true }
          } }
        )
      end
    end

    def bundle
      in_tenant(@agency) { Fhir::PreAdmitEvalBundle.new(@eval).as_bundle }
    end

    test "emits a FHIR R4 document Bundle led by a Composition" do
      b = bundle
      assert_equal "Bundle",      b[:resourceType]
      assert_equal "document",    b[:type]
      assert b[:timestamp].present?
      first = b[:entry].first[:resource]
      assert_equal "Composition", first[:resourceType]
      assert_equal "final",       first[:status], "certified eval is a final composition"
    end

    test "every entry has a unique urn:uuid fullUrl and no reference dangles" do
      b    = bundle
      urls = b[:entry].map { |e| e[:fullUrl] }
      assert urls.all? { |u| u.start_with?("urn:uuid:") }, "all fullUrls are urn:uuid"
      assert_equal urls.length, urls.uniq.length, "fullUrls are unique"
      deep_references(b).each do |r|
        assert_includes urls, r, "reference #{r} resolves to a bundle entry"
      end
    end

    test "maps the primary diagnosis to a confirmed ICD-10-CM Condition" do
      cond   = resource_of(bundle, "Condition")
      coding = cond[:code][:coding].first
      assert_equal "http://hl7.org/fhir/sid/icd-10-cm", coding[:system]
      assert_equal "C34.90", coding[:code]
      assert_equal "Malignant neoplasm of lung", coding[:display]
      assert_equal "confirmed", cond[:verificationStatus][:coding].first[:code]
    end

    test "maps demographics and language onto the Patient" do
      p = resource_of(bundle, "Patient")
      assert_equal "female",   p[:gender]
      assert_equal "Gonzalez", p[:name].first[:family]
      assert_equal "33101",    p[:address].first[:postalCode]
      assert_equal "es-ES",    p[:communication].first[:language][:coding].first[:code]
    end

    test "PPS becomes an Observation and each signed form becomes a Consent" do
      b   = bundle
      obs = resource_of(b, "Observation")
      assert_equal 40, obs[:valueQuantity][:value]
      assert_equal 2, all_resources(b, "Consent").length
    end

    test "consents differentiate election vs rights by scope and link the electing agency" do
      b        = bundle
      consents = all_resources(b, "Consent")
      assert_equal 2, consents.length

      by_policy = consents.index_by { |c| c[:policyRule][:text] }
      election  = by_policy["Medicare Hospice Election of Benefits"]
      rights    = by_policy["Patient Rights reviewed"]
      assert_equal "treatment",       election[:scope][:coding].first[:code]
      assert_equal "patient-privacy", rights[:scope][:coding].first[:code]

      # Both provision.actor references resolve to the Organization entry.
      org_url = b[:entry].find { |e| e[:resource][:resourceType] == "Organization" }[:fullUrl]
      consents.each do |c|
        actor = c[:provision][:actor].first
        assert_equal org_url, actor[:reference][:reference], "actor links the hospice agency"
        assert_equal "PRF",   actor[:role][:coding].first[:code]
      end
    end

    test "a certified eval carries a Provenance signature targeting the Composition" do
      b    = bundle
      prov = resource_of(b, "Provenance")
      assert_equal b[:entry].first[:fullUrl], prov[:target].first[:reference]
      assert prov[:signature].first[:when].present?
    end

    test "an RN-finalized but uncertified eval is still a preliminary Composition" do
      in_tenant(@agency) { @eval.update!(status: :final, certified_at: nil) }
      b = bundle
      assert_equal "preliminary", b[:entry].first[:resource][:status], "not MD-certified yet"
      assert_nil resource_of(b, "Provenance"), "no signature until certified"
      assert_equal "provisional", resource_of(b, "Condition")[:verificationStatus][:coding].first[:code]
    end

    test "a draft eval is a preliminary Composition with no Provenance" do
      in_tenant(@agency) { @eval.update!(status: :draft, certified_at: nil) }
      b = bundle
      assert_equal "preliminary", b[:entry].first[:resource][:status]
      assert_nil resource_of(b, "Provenance")
      assert_equal "provisional", resource_of(b, "Condition")[:verificationStatus][:coding].first[:code]
    end

    test "compile_vitas_payload stays legacy by default and opts into FHIR via env" do
      legacy = in_tenant(@agency) { @eval.compile_vitas_payload }
      assert_equal "Encounter", legacy[:resource_type]

      ENV["EMR_PAYLOAD_FORMAT"] = "fhir"
      fhir = in_tenant(@agency) { @eval.compile_vitas_payload }
      assert_equal "Bundle", fhir[:resourceType]
    ensure
      ENV.delete("EMR_PAYLOAD_FORMAT")
    end

    test "comfort-kit orders become MedicationRequests in their own section" do
      in_tenant(@agency) do
        MedicationOrder.create!(agency: @agency, patient: @patient, prescribed_by: @rn,
          pre_admit_eval: @eval, drug_name: "Roxanol (morphine concentrate)", dose: "5 mg", frequency: "q2h", route: :sl,
          start_date: Date.current, status: :draft, comfort_kit: true, prn: true,
          prn_indication: "pain or dyspnea")
        MedicationOrder.create!(agency: @agency, patient: @patient, prescribed_by: @rn,
          pre_admit_eval: @eval, drug_name: "Atropine 1% Ophthalmic Solution", dose: "1% ophthalmic solution",
          frequency: "q1h", route: :sl, start_date: Date.current, status: :draft, comfort_kit: true,
          prn: true, prn_indication: "terminal secretions")
        # A non-comfort-kit order on the same eval must NOT appear.
        MedicationOrder.create!(agency: @agency, patient: @patient, prescribed_by: @rn,
          pre_admit_eval: @eval, drug_name: "Ibuprofen", dose: "200 mg", frequency: "daily", route: :po,
          start_date: Date.current, status: :active, comfort_kit: false)
      end

      b    = bundle
      meds = all_resources(b, "MedicationRequest")
      assert_equal 2, meds.length, "only comfort-kit orders are included"

      morphine = meds.find { |m| m[:medicationCodeableConcept][:text].include?("morphine") }
      assert_equal "draft",    morphine[:status]
      assert_equal "proposal", morphine[:intent], "an unauthorized comfort-kit item is a proposal"

      # RxNorm ingredient coding, raw name kept as text.
      coding = morphine[:medicationCodeableConcept][:coding].first
      assert_equal "http://www.nlm.nih.gov/research/umls/rxnorm", coding[:system]
      assert_equal "7052", coding[:code]
      assert_equal "Morphine", coding[:display]

      dosage = morphine[:dosageInstruction].first
      assert_equal "pain or dyspnea", dosage[:asNeededCodeableConcept][:text]
      assert_match(/sublingual/, dosage[:route][:text])
      # Structured, UCUM-coded dose.
      dq = dosage[:doseAndRate].first[:doseQuantity]
      assert_equal 5, dq[:value]
      assert_equal "mg", dq[:unit]
      assert_equal "mg", dq[:code]
      assert_equal "http://unitsofmeasure.org", dq[:system]

      # Atropine is coded but its "1% ophthalmic solution" dose stays text-only.
      atropine = meds.find { |m| m[:medicationCodeableConcept][:text].include?("Atropine") }
      assert_equal "1223", atropine[:medicationCodeableConcept][:coding].first[:code]
      assert_nil atropine[:dosageInstruction].first[:doseAndRate], "non-numeric dose is not structured"

      # The Composition gets a comfort-kit section whose references resolve.
      urls    = b[:entry].map { |e| e[:fullUrl] }
      section = b[:entry].first[:resource][:section].find { |s| s[:title] == "Comfort-kit medication orders" }
      assert section, "comfort-kit section present"
      section[:entry].each { |e| assert_includes urls, e[:reference], "section reference resolves to an entry" }
    end

    private

    def resource_of(bundle, type)
      bundle[:entry].map { |e| e[:resource] }.find { |r| r[:resourceType] == type }
    end

    def all_resources(bundle, type)
      bundle[:entry].map { |e| e[:resource] }.select { |r| r[:resourceType] == type }
    end

    # Recursively collect every { reference: "urn:uuid:…" } value in the bundle.
    def deep_references(obj, acc = [])
      case obj
      when Hash
        obj.each { |k, v| k == :reference && v.is_a?(String) ? acc << v : deep_references(v, acc) }
      when Array
        obj.each { |v| deep_references(v, acc) }
      end
      acc
    end
  end
end
