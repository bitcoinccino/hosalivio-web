require "test_helper"

module Fhir
  class ReferralIngestTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup { @agency = create_agency }

    # fullUrl is derived from resource id so requester references resolve.
    def bundle(resources)
      { "resourceType" => "Bundle", "type" => "collection",
        "entry" => resources.map { |r| { "fullUrl" => "urn:uuid:#{r['id'] || r['resourceType'].downcase}", "resource" => r } } }
    end

    def org(name = "Sunrise Medical Center")
      { "resourceType" => "Organization", "id" => "org-1", "name" => name }
    end

    def patient(overrides = {})
      {
        "resourceType" => "Patient", "id" => "pat-1",
        "identifier" => [ { "type" => { "coding" => [ { "code" => "MR" } ] }, "value" => "MRN-555" } ],
        "name"       => [ { "use" => "official", "family" => "Gonzalez", "given" => [ "Maria" ] } ],
        "birthDate"  => "1940-03-02",
        "telecom"    => [ { "system" => "phone", "value" => "305-555-0100" } ],
        "address"    => [ { "postalCode" => "33101" } ]
      }.merge(overrides)
    end

    def service_request(overrides = {})
      {
        "resourceType" => "ServiceRequest", "id" => "sr-1", "status" => "active", "intent" => "order",
        "identifier"   => [ { "system" => "https://sunrise/ref", "value" => "REF-9001" } ],
        "subject"      => { "reference" => "urn:uuid:pat-1" },
        "requester"    => { "reference" => "urn:uuid:org-1" },
        "priority"     => "urgent",
        "code"         => { "text" => "Hospice evaluation" },
        "reasonCode"   => [ { "text" => "End-stage lung cancer, declining" } ],
        "authoredOn"        => "2026-06-30T12:00:00Z",
        "occurrenceDateTime" => "2026-07-03T00:00:00Z",
        "note"         => [ { "text" => "Family requests urgent contact." } ]
      }.merge(overrides)
    end

    def condition(code, display = "Some diagnosis")
      { "resourceType" => "Condition",
        "code" => { "coding" => [ { "system" => "http://hl7.org/fhir/sid/icd-10-cm", "code" => code, "display" => display } ], "text" => display } }
    end

    def ingest(b)
      Fhir::ReferralIngest.new(b, agency: @agency).call
    end

    test "maps a full referral bundle onto an enriched Inquiry" do
      r = ingest(bundle([ org, patient, service_request, condition("C34.90", "Malignant neoplasm of lung") ]))
      assert r.ok?
      assert_not r.duplicate?
      i = r.inquiry

      assert_equal "Maria",         i.first_name
      assert_equal "Gonzalez",      i.last_name
      assert_equal "1940-03-02",    i.dob
      assert_equal "MRN-555",       i.external_mrn
      assert_equal "305-555-0100",  i.contact
      assert_equal "33101",         i.zip
      assert_equal "Cancer",        i.diagnosis, "Condition C34.90 buckets to Cancer"
      assert_equal "Sunrise Medical Center",     i.referring_provider
      assert_equal "Hospice evaluation",         i.requested_service
      assert_equal "Malignant neoplasm of lung", i.reason_for_referral, "internal Condition wins over reasonCode"
      assert_equal "urgent",        i.urgency
      assert_equal "REF-9001",      i.external_referral_id
      assert i.referral_date.present?
      assert i.desired_date.present?
      assert_includes i.raw_fhir_payload, "ServiceRequest", "raw payload persisted for audit"
      assert_equal "fhir_referral", i.source_prompt
      assert i.status_new_lead?
    end

    test "captures an NPI the referral already carries on the requester" do
      practitioner = {
        "resourceType" => "Practitioner", "id" => "org-1",
        "identifier" => [ { "system" => "http://hl7.org/fhir/sid/us-npi", "value" => "1679567796" } ],
        "name" => [ { "family" => "Smith", "given" => [ "John" ] } ]
      }
      # requester resolves to urn:uuid:org-1 (see service_request default)
      r = ingest(bundle([ practitioner, patient, service_request ]))
      assert r.ok?
      assert_equal "1679567796", r.inquiry.referring_provider_npi
    end

    test "leaves the NPI nil when none is carried and NPPES is dormant (test env)" do
      # org has no NPI identifier; live NPPES lookup is off in test → nil, no stall.
      r = ingest(bundle([ org, patient, service_request ]))
      assert r.ok?
      assert_nil r.inquiry.referring_provider_npi
    end

    test "dedupes a re-sent referral by external_referral_id" do
      first = ingest(bundle([ org, patient, service_request ]))
      assert first.ok?
      assert_difference -> { ActsAsTenant.with_tenant(@agency) { Inquiry.count } }, 0 do
        again = ingest(bundle([ org, patient, service_request ]))
        assert again.duplicate?
        assert_equal first.inquiry.id, again.inquiry.id
      end
    end

    test "a RelatedPerson submitter is family and can supply the contact point" do
      related = { "resourceType" => "RelatedPerson", "telecom" => [ { "system" => "phone", "value" => "786-555-0199" } ] }
      r = ingest(bundle([ org, patient("telecom" => nil), related, service_request ]))
      assert r.ok?
      assert_equal "Caregiver or Family Member", r.inquiry.requester_role
      assert_equal "786-555-0199", r.inquiry.contact
    end

    test "creating the inquiry fans out to the on-call coordinator pipeline" do
      assert_enqueued_with(job: InquiryAlertJob) do
        ingest(bundle([ org, patient, service_request ]))
      end
    end

    test "falls back to reasonCode for the reason when no Condition is present" do
      r = ingest(bundle([ org, patient, service_request ]))
      assert_equal "End-stage lung cancer, declining", r.inquiry.reason_for_referral
    end

    test "the only hard reject is a missing Patient resource" do
      no_patient = ingest(bundle([ service_request ]))
      assert_not no_patient.ok?
      assert_match(/Patient/, no_patient.issues.first[:expression])
    end

    test "degrades gracefully: creates a lead even when optional data is missing" do
      # No provider, no clinical intent, and no patient contact — but a referral
      # id makes contact optional, so we still capture the lead.
      thin = ingest(bundle([ patient("telecom" => nil), service_request.except("requester", "code", "reasonCode") ]))
      assert thin.ok?, "graceful degradation still creates a lead"
      i = thin.inquiry
      assert_nil i.referring_provider
      assert_nil i.requested_service
      assert_nil i.reason_for_referral
      assert_nil i.contact
      assert_equal "REF-9001", i.external_referral_id
    end

    test "rejects a non-Bundle payload" do
      assert_raises(Fhir::ReferralIngest::InvalidBundle) { ingest({ "resourceType" => "Patient" }) }
    end
  end
end
