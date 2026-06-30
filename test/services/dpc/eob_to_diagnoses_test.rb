require "test_helper"

class Dpc::EobToDiagnosesTest < ActiveSupport::TestCase
  def eob(icd:, date:, display: "", system: "http://hl7.org/fhir/sid/icd-10-cm")
    {
      resourceType: "ExplanationOfBenefit",
      billablePeriod: { start: date, end: date },
      diagnosis: [ { sequence: 1, diagnosisCodeableConcept: { coding: [ { system: system, code: icd, display: display } ] } } ]
    }.to_json
  end

  test "rolls up diagnoses across EOBs — newest first, with occurrence counts" do
    ndjson = [
      eob(icd: "I50.9", display: "Heart failure, unspecified", date: "2025-01-10"),
      eob(icd: "I50.9", display: "Heart failure, unspecified", date: "2025-03-15"),
      eob(icd: "N18.6", display: "End stage renal disease",    date: "2025-02-01"),
      "not json at all",
      { resourceType: "Patient", id: "x" }.to_json
    ].join("\n")

    rows = Dpc::EobToDiagnoses.call(ndjson)
    assert_equal %w[I50.9 N18.6], rows.map(&:icd10), "I50.9 (latest Mar) sorts before N18.6 (Feb)"
    assert_equal 2, rows.first.count
    assert_equal Date.new(2025, 3, 15), rows.first.last_seen
    assert_equal "Heart failure, unspecified", rows.first.description
  end

  test "ignores non-ICD-10 codings and empty/blank input" do
    snomed = { resourceType: "ExplanationOfBenefit",
               diagnosis: [ { diagnosisCodeableConcept: { coding: [ { system: "http://snomed.info/sct", code: "X" } ] } } ] }.to_json
    assert_empty Dpc::EobToDiagnoses.call(snomed)
    assert_empty Dpc::EobToDiagnoses.call("")
    assert_empty Dpc::EobToDiagnoses.call(nil)
  end

  test "falls back to the local ICD-10 index for description when the EOB carries none" do
    Icd10Code.create!(code: "J44.9", description: "Chronic obstructive pulmonary disease, unspecified")
    row = Dpc::EobToDiagnoses.call(eob(icd: "J44.9", date: "2025-01-01")).first
    assert_equal "Chronic obstructive pulmonary disease, unspecified", row.description
  end
end
