require "test_helper"

module Api
  class ReferralsTest < ActionDispatch::IntegrationTest
    setup do
      @agency = create_agency
      @token  = AgentToken.encode(role: "admissions", agency_id: @agency.id)
    end

    def auth = { "Authorization" => "Bearer #{@token}", "Content-Type" => "application/fhir+json" }

    # A schema-valid R4 referral bundle.
    def referral(overrides = {})
      sr = {
        resourceType: "ServiceRequest", id: "sr-1", status: "active", intent: "order",
        identifier: [ { system: "https://sunrise.example/referrals", value: "REF-9001" } ],
        subject: { reference: "urn:uuid:pat-1" },
        requester: { reference: "urn:uuid:org-1" },
        priority: "urgent",
        code: { text: "Hospice evaluation" },
        reasonCode: [ { text: "End-stage lung cancer, declining" } ],
        authoredOn: "2026-06-30T12:00:00Z"
      }.merge(overrides)

      {
        resourceType: "Bundle", type: "collection",
        entry: [
          { fullUrl: "urn:uuid:org-1", resource: { resourceType: "Organization", id: "org-1", name: "Sunrise Medical Center" } },
          { fullUrl: "urn:uuid:pat-1", resource: {
              resourceType: "Patient", id: "pat-1",
              identifier: [ { type: { coding: [ { system: "http://terminology.hl7.org/CodeSystem/v2-0203", code: "MR" } ] }, value: "MRN-555" } ],
              name: [ { use: "official", family: "Gonzalez", given: [ "Maria" ] } ],
              birthDate: "1940-03-02",
              telecom: [ { system: "phone", value: "305-555-0100" } ],
              address: [ { postalCode: "33101" } ] } },
          { fullUrl: "urn:uuid:sr-1", resource: sr }
        ]
      }
    end

    def post_referral(payload, headers: auth)
      post "/api/v1/referrals", params: payload.to_json, headers: headers
    end

    def count = ActsAsTenant.with_tenant(@agency) { Inquiry.count }

    test "accepts a valid referral and creates an enriched inquiry in the token's agency" do
      assert_difference -> { count }, 1 do
        post_referral(referral)
      end
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal "OperationOutcome", body["resourceType"]
      assert body["inquiry_id"].present?
      assert_equal false, body["duplicate"]

      i = ActsAsTenant.with_tenant(@agency) { Inquiry.order(:created_at).last }
      assert_equal "Gonzalez", i.last_name
      assert_equal "Sunrise Medical Center", i.referring_provider
      assert_equal "REF-9001", i.external_referral_id
      assert_equal "urgent", i.urgency
    end

    test "dedupes a re-sent referral (200, same inquiry, no new record)" do
      post_referral(referral)
      assert_response :created

      assert_difference -> { count }, 0 do
        post_referral(referral)
      end
      assert_response :ok
      assert_equal true, JSON.parse(response.body)["duplicate"]
    end

    test "rejects an unauthenticated request" do
      post_referral(referral, headers: { "Content-Type" => "application/fhir+json" })
      assert_response :unauthorized
    end

    test "rejects a payload that fails FHIR schema validation with per-element OperationOutcome" do
      # ServiceRequest without required status/intent → schema error.
      bad = referral
      bad[:entry][2][:resource].delete(:status)
      bad[:entry][2][:resource].delete(:intent)
      assert_difference -> { count }, 0 do
        post_referral(bad)
      end
      assert_response :unprocessable_entity
      body = JSON.parse(response.body)
      assert_equal "OperationOutcome", body["resourceType"]
      assert body["issue"].any? { |x| x["expression"].to_s.include?("status") || x["expression"].to_s.include?("intent") },
             "issue points at the offending element"
    end

    test "accepts a schema-valid referral missing optional fields (graceful degradation)" do
      # Drop the requester → passes schema, and we still capture the lead rather
      # than reject it (maximize top-of-funnel intake).
      incomplete = referral
      incomplete[:entry][2][:resource].delete(:requester)
      assert_difference -> { count }, 1 do
        post_referral(incomplete)
      end
      assert_response :created
      i = ActsAsTenant.with_tenant(@agency) { Inquiry.order(:created_at).last }
      assert_nil i.referring_provider, "missing optional field degrades to nil, not a 422"
    end

    test "returns a 400 for invalid JSON" do
      post "/api/v1/referrals", params: "{ not json", headers: auth
      assert_response :bad_request
    end
  end
end
