require "test_helper"

# The redesigned Safety & functional status modal is a widget change only
# (selects → segmented toggles, same field names). This locks the data contract:
# the params those toggles submit must still round-trip into raw_json.
class EvalSafetyFunctionalEditTest < ActionDispatch::IntegrationTest
  setup do
    @agency  = create_agency
    @rn      = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    @patient = create_patient(agency: @agency)
    @eval    = in_tenant(@agency) do
      PreAdmitEval.create!(agency: @agency, patient: @patient, evaluator: @rn,
        evaluator_name: "Reggie RN", evaluated_at: Time.current, status: :draft,
        raw_json: { "pre_admit_eval" => {} })
    end
  end

  test "safety/functional toggle + narrative fields persist through update" do
    sign_in @rn
    patch pre_admit_eval_path(@eval), params: {
      submit_action: "save",
      pre_admit_eval: {
        functional_decline: {
          mobility: "Chairfast",
          fall_history: "High fall risk",
          adl_dependencies: { bathing: "Dependent", feeding: "Assist", transferring: "Independent" },
          recent_functional_changes: "Declining over the past week."
        },
        general: {
          advance_directives: "DNR",
          spiritual_bereavement_risk: "Moderate",
          notes: "Home O2 in place."
        }
      }
    }

    @eval.reload
    fd  = @eval.functional_decline
    gen = @eval.general
    assert_equal "Chairfast",       fd["mobility"]
    assert_equal "High fall risk",  fd["fall_history"]
    assert_equal "Dependent",       fd.dig("adl_dependencies", "bathing")
    assert_equal "Assist",          fd.dig("adl_dependencies", "feeding")
    assert_equal "Declining over the past week.", fd["recent_functional_changes"]
    assert_equal "DNR",             gen["advance_directives"]
    assert_equal "Moderate",        gen["spiritual_bereavement_risk"]
  end

  test "diagnosis, key-findings and summary modal fields persist through update" do
    sign_in @rn
    patch pre_admit_eval_path(@eval), params: {
      submit_action: "save",
      pre_admit_eval: {
        diagnosis: { primary_terminal_diagnosis: { description: "Lung cancer", icd10: "C34.90" }, lcd_criteria_met: "PPS <= 70%, dyspnea" },
        medicare_lcd_criteria: { supporting_documentation: "Documented decline." },
        functional_decline: { pps: { score: "40", source: "clinician", justification: "bedbound most of day" }, kps: "40" },
        general_comments: { history_of_present_illness: "worsening", narrative_summary: "declining", family_caregiver_status: "Lives alone" },
        final_review: { hospice_eligibility_statement: "clearly eligible", rn_recommendation: "admit" }
      }
    }

    @eval.reload
    assert_equal "C34.90",     @eval.diagnosis_section.dig("primary_terminal_diagnosis", "icd10")
    assert_equal "clinician",  @eval.functional_decline.dig("pps", "source")
    assert_equal "bedbound most of day", @eval.functional_decline.dig("pps", "justification")
    assert_equal "Lives alone", @eval.general_comments["family_caregiver_status"]
    assert_equal "declining",  @eval.general_comments["narrative_summary"]
    assert_equal "clearly eligible", @eval.final_review_section["hospice_eligibility_statement"]
  end
end
