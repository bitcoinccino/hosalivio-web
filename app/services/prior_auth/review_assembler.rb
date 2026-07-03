module PriorAuth
  # Stage 4: assemble a PriorAuthReview from a request + the patient's extracted
  # documents (see docs/prior-auth-slice.md). Finds the governing policy by HCPCS,
  # runs Stage 2 (which grounds each finding via Stage 3), persists the review and
  # its criterion_results, and derives the recommendation. Returns the review, or
  # nil when no active policy governs the requested procedure.
  #
  # Caller runs inside the tenant (ActsAsTenant.with_tenant); agency is taken from
  # the patient.
  class ReviewAssembler
    def self.call(patient:, procedure_hcpcs:, provider_npi: nil, document_texts: [])
      policy = CoveragePolicy.for_hcpcs(procedure_hcpcs)
      return nil unless policy

      results = CriterionExtractor.call(policy: policy, document_texts: document_texts)
      review = PriorAuthReview.create!(
        agency:          patient.agency,
        patient:         patient,
        coverage_policy: policy,
        procedure_hcpcs: procedure_hcpcs.to_s.strip.upcase,
        provider_npi:    provider_npi.presence,
        status:          :draft
      )
      review.record_results(results)
    end
  end
end
