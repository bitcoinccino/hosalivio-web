require "test_helper"
require "fhir_models"

# Validates the FHIR bundles we *generate* against the official HL7 FHIR R4
# StructureDefinitions (bundled in fhir_models). This is the schema-conformance
# gate the earlier hand-rolled structural tests couldn't provide.
module Fhir
  class SchemaConformanceTest < ActiveSupport::TestCase
    setup do
      @agency  = create_agency
      @rn      = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
      @patient = create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez")
      in_tenant(@agency) do
        @patient.update!(gender: "female", zip: "33101", phone: "305-555-0100",
                         email: "maria@example.com", preferred_language: "es")
      end
    end

    def full_json
      { "pre_admit_eval" => {
        "diagnosis" => { "primary_terminal_diagnosis" => { "icd10" => "C34.90", "description" => "Malignant neoplasm of lung" } },
        "functional_decline" => { "pps" => { "score" => 40 } },
        "general" => { "election_of_benefits_signed" => true, "patient_rights_reviewed" => true }
      } }
    end

    def build_eval(raw_json:, **attrs)
      in_tenant(@agency) do
        PreAdmitEval.create!({
          agency: @agency, patient: @patient, evaluator: @rn,
          evaluator_name: "Reggie RN", evaluator_role: "rn", evaluated_at: Time.current,
          raw_json: raw_json
        }.merge(attrs))
      end
    end

    def bundle_for(eval_record)
      in_tenant(@agency) { Fhir::PreAdmitEvalBundle.new(eval_record).as_bundle }
    end

    def assert_fhir_valid(hash)
      model = FHIR.from_contents(hash.to_json)
      assert model, "fhir_models could not parse the payload"
      assert model.valid?, "FHIR R4 schema errors:\n#{JSON.pretty_generate(model.validate)}"
      model
    end

    test "a certified eval bundle (diagnosis, PPS, consents, meds, provenance) conforms to FHIR R4" do
      e = build_eval(raw_json: full_json, status: :certified, certified_at: Time.current, certified_by: @rn)
      in_tenant(@agency) do
        MedicationOrder.create!(agency: @agency, patient: @patient, prescribed_by: @rn, pre_admit_eval: e,
          drug_name: "Roxanol (morphine concentrate)", dose: "5 mg", frequency: "q2h", route: :sl,
          start_date: Date.current, status: :draft, comfort_kit: true, prn: true, prn_indication: "pain")
        MedicationOrder.create!(agency: @agency, patient: @patient, prescribed_by: @rn, pre_admit_eval: e,
          drug_name: "Atropine 1% Ophthalmic Solution", dose: "1% ophthalmic solution", frequency: "q1h",
          route: :sl, start_date: Date.current, status: :draft, comfort_kit: true, prn: true, prn_indication: "secretions")
      end

      model = assert_fhir_valid(bundle_for(e))
      assert_equal "FHIR::R4::Bundle", model.class.name

      # Every contained resource must individually conform, too.
      model.entry.each do |entry|
        r = entry.resource
        assert r.valid?, "#{r.resourceType} errors:\n#{JSON.pretty_generate(r.validate)}"
      end
    end

    test "a minimal draft eval bundle (no diagnosis/consents/meds/provenance) conforms to FHIR R4" do
      e = build_eval(raw_json: { "pre_admit_eval" => {} }, status: :draft)
      assert_fhir_valid(bundle_for(e))
    end

    test "an eval bundle with a text-only (un-indexed) diagnosis still conforms" do
      json = { "pre_admit_eval" => {
        "diagnosis" => { "primary_terminal_diagnosis" => { "icd10" => "Z9999", "description" => "Unusual condition" } }
      } }
      e = build_eval(raw_json: json, status: :final)
      assert_fhir_valid(bundle_for(e))
    end
  end
end
