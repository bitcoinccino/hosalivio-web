require "test_helper"

module Api
  class ReferralsTest < ActionDispatch::IntegrationTest
    setup do
      @agency = create_agency
      @token  = AgentToken.encode(role: "admissions", agency_id: @agency.id)
    end

    def bundle_json
      {
        resourceType: "Bundle", type: "message",
        entry: [
          { resource: { resourceType: "Patient",
                        name: [ { use: "official", family: "Gonzalez", given: [ "Maria" ] } ],
                        birthDate: "1940-03-02",
                        telecom: [ { system: "phone", value: "305-555-0100" } ],
                        address: [ { postalCode: "33101" } ] } },
          { resource: { resourceType: "Condition",
                        code: { coding: [ { system: "http://hl7.org/fhir/sid/icd-10-cm", code: "C34.90" } ],
                                text: "Malignant neoplasm of lung" } } }
        ]
      }.to_json
    end

    def auth = { "Authorization" => "Bearer #{@token}", "Content-Type" => "application/json" }

    test "accepts a referral bundle and creates an inquiry in the token's agency" do
      assert_difference -> { ActsAsTenant.with_tenant(@agency) { Inquiry.count } }, 1 do
        post "/api/v1/referrals", params: bundle_json, headers: auth
      end
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal "OperationOutcome", body["resourceType"]
      assert body["inquiry_id"].present?

      i = ActsAsTenant.with_tenant(@agency) { Inquiry.order(:created_at).last }
      assert_equal "Gonzalez", i.last_name
      assert_equal "Cancer",   i.diagnosis
    end

    test "rejects an unauthenticated request" do
      post "/api/v1/referrals", params: bundle_json, headers: { "Content-Type" => "application/json" }
      assert_response :unauthorized
    end

    test "returns an OperationOutcome error for a malformed bundle" do
      post "/api/v1/referrals", params: { resourceType: "Patient" }.to_json, headers: auth
      assert_response :unprocessable_entity
      body = JSON.parse(response.body)
      assert_equal "OperationOutcome", body["resourceType"]
      assert_equal "error", body["issue"].first["severity"]
    end

    test "returns a 400 for invalid JSON" do
      post "/api/v1/referrals", params: "{ not json", headers: auth
      assert_response :bad_request
    end
  end
end
