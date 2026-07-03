require "test_helper"

class Intake::NarrativeExtractorTest < ActiveSupport::TestCase
  setup { @agency = create_agency }

  test "extracts the spoken intake fields into normalized values" do
    patient = in_tenant(@agency) { create_patient(agency: @agency) }
    narrative = "Patient is a widowed veteran who served in the Army. She lives in a nursing home. " \
                "Her daughter is her primary caregiver. Attending physician Dr. Smith manages her care. Patient is DNR."

    out = in_tenant(@agency) { Intake::NarrativeExtractor.call(narrative: narrative, patient: patient) }

    assert_equal "Widowed",                  out["marital_status"]
    assert_equal "Skilled nursing facility", out["living_arrangements"]
    assert_equal "Veteran",                  out["veteran_status"]
    assert_equal "Daughter",                 out["caregiver_relationship"]
    assert_equal "dnr",                      out["code_status"]
    assert out["attending_physician_name"].to_s.start_with?("Dr. Smith")
  end

  test "never offers a field the patient already has (blanks-only)" do
    patient = in_tenant(@agency) do
      p = create_patient(agency: @agency)
      p.update!(veteran_status: "Veteran", caregiver_relationship: "Son",
                code_status: "dnr", intake: { "marital_status" => "Single" })
      p
    end

    out = in_tenant(@agency) do
      Intake::NarrativeExtractor.call(
        narrative: "Widowed veteran, DNR, lives at home, wife is the caregiver.", patient: patient
      )
    end

    assert_nil out["veteran_status"],         "already set"
    assert_nil out["caregiver_relationship"], "already set"
    assert_nil out["code_status"],            "already non-default (dnr)"
    assert_nil out["marital_status"],         "intake already set"
    assert_equal "Private home", out["living_arrangements"], "this field was blank, so offered"
  end

  test "returns empty when the narrative has no intake signals" do
    patient = in_tenant(@agency) { create_patient(agency: @agency) }
    out = in_tenant(@agency) do
      Intake::NarrativeExtractor.call(narrative: "Vitals stable. Resting comfortably in bed.", patient: patient)
    end
    assert_empty out
  end
end
