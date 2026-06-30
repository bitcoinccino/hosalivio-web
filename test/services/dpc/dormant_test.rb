require "test_helper"

# DPC stays inert until credentialed — safe to ship dormant.
class Dpc::DormantTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @patient = create_patient(agency: @agency)
  end

  def new_eval(raw = { "pre_admit_eval" => {} })
    in_tenant(@agency) { PreAdmitEval.create!(agency: @agency, patient: @patient, raw_json: raw) }
  end

  test "not configured without env, and the client returns [] (no network)" do
    refute Dpc.configured?
    assert_empty Dpc::Client.new.diagnoses_for("patient-123")
  end

  test "enqueue_dpc_import is a no-op when unconfigured" do
    assert_equal false, new_eval.enqueue_dpc_import("patient-123")
  end

  test "the import job no-ops when unconfigured (eval untouched)" do
    ev = new_eval
    DpcClaimsImportJob.perform_now(ev.id, "patient-123")
    assert_nil in_tenant(@agency) { ev.reload.medicare_claims_history }
  end

  test "medicare_claims_history reads the stored DPC payload" do
    ev = new_eval("pre_admit_eval" => { "diagnosis" => {
      "medicare_claims_history" => { "source" => "DPC",
        "diagnoses" => [ { "icd10" => "I50.9", "description" => "Heart failure" } ] } } })
    in_tenant(@agency) do
      assert_equal "DPC", ev.medicare_claims_history["source"]
      assert_equal "I50.9", ev.medicare_claims_history["diagnoses"].first["icd10"]
    end
  end
end
