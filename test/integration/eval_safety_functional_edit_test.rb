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
end
