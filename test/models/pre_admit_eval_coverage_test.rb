require "test_helper"

class PreAdmitEvalCoverageTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @patient = create_patient(agency: @agency)
    Icd10Code.create!(code: "I50.9", description: "Heart failure, unspecified")
  end

  def eval_with(code)
    in_tenant(@agency) do
      PreAdmitEval.create!(agency: @agency, patient: @patient,
        raw_json: { "pre_admit_eval" => { "diagnosis" => {
          "primary_terminal_diagnosis" => { "icd10" => code, "description" => "entered" } } } })
    end
  end

  test "verified code maps to its hospice LCD" do
    ev = eval_with("I50.9")
    in_tenant(@agency) do
      assert ev.icd10_in_index?
      assert_equal :likely_covered, ev.cms_coverage.status
      assert_equal "L34548", ev.cms_coverage.lcd_id # Hospice Cardiopulmonary Conditions
    end
  end

  test "code not in index + non-terminal coverage are flagged" do
    ev = eval_with("A09") # not added to Icd10Code
    in_tenant(@agency) do
      refute ev.icd10_in_index?
      assert_equal :needs_review, ev.cms_coverage.status
    end
  end
end
