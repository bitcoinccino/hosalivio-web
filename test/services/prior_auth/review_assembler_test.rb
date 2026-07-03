require "test_helper"

class PriorAuth::ReviewAssemblerTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @patient = in_tenant(@agency) { create_patient(agency: @agency) }
    @policy  = CoveragePolicy.create!(title: "Hospice LCD", payer: "medicare", source_type: "lcd",
                                      document_id: "L34538", procedure_hcpcs: %w[Q5001])
    @policy.criteria.create!(label: "PPS <= 70%", position: 0)
    @policy.criteria.create!(label: ">= 3 ADLs",  position: 1)
  end

  test "assembles a draft review for a governed procedure" do
    # LLM is dormant in test, so every criterion comes back not_documented -> gap.
    rev = in_tenant(@agency) do
      PriorAuth::ReviewAssembler.call(patient: @patient, procedure_hcpcs: "q5001", provider_npi: "1578671483")
    end

    assert rev.persisted?
    assert rev.status_draft?
    assert_equal @policy, rev.coverage_policy
    assert_equal "Q5001", rev.procedure_hcpcs        # normalized
    assert_equal 2, rev.criterion_results.count       # one per policy criterion
    assert rev.recommendation_gap?                    # nothing grounded without an LLM
  end

  test "returns nil when no active policy governs the procedure" do
    rev = in_tenant(@agency) do
      PriorAuth::ReviewAssembler.call(patient: @patient, procedure_hcpcs: "99999")
    end
    assert_nil rev
  end
end
