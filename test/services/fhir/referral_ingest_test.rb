require "test_helper"

module Fhir
  class ReferralIngestTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup { @agency = create_agency }

    def bundle(entries)
      { "resourceType" => "Bundle", "type" => "message", "entry" => entries.map { |r| { "resource" => r } } }
    end

    def patient(overrides = {})
      {
        "resourceType" => "Patient",
        "name"      => [ { "use" => "official", "family" => "Gonzalez", "given" => [ "Maria" ] } ],
        "birthDate" => "1940-03-02",
        "telecom"   => [ { "system" => "phone", "value" => "305-555-0100" },
                         { "system" => "email", "value" => "maria@example.com" } ],
        "address"   => [ { "postalCode" => "33101" } ]
      }.merge(overrides)
    end

    def condition(code, display = "Some diagnosis")
      { "resourceType" => "Condition",
        "code" => { "coding" => [ { "system" => "http://hl7.org/fhir/sid/icd-10-cm", "code" => code, "display" => display } ],
                    "text" => display } }
    end

    def service_request(note = "Please evaluate for hospice.")
      { "resourceType" => "ServiceRequest", "status" => "active", "intent" => "order",
        "note" => [ { "text" => note } ] }
    end

    def ingest(b)
      Fhir::ReferralIngest.new(b, agency: @agency).call
    end

    test "maps a full referral bundle onto an encrypted Inquiry" do
      i = ingest(bundle([ service_request, patient, condition("C34.90", "Malignant neoplasm of lung") ]))

      assert_equal "Maria",         i.first_name
      assert_equal "Gonzalez",      i.last_name
      assert_equal "1940-03-02",    i.dob
      assert_equal "305-555-0100",  i.caregiver_phone
      assert_equal "maria@example.com", i.email
      assert_equal "305-555-0100",  i.contact, "phone preferred as the canonical contact"
      assert_equal "33101",         i.zip
      assert_equal "Cancer",        i.diagnosis, "C34.90 buckets to Cancer"
      assert_equal "fhir_referral", i.source_prompt
      assert_not i.is_general
      assert i.status_new_lead?
      assert_includes i.question, "Malignant neoplasm of lung"
      assert_includes i.question, "Please evaluate for hospice."
    end

    test "buckets diagnoses by ICD-10 prefix" do
      heart = ingest(bundle([ patient, condition("I50.9", "Heart failure") ]))
      assert_equal "Heart disease (CHF)", heart.diagnosis

      renal = ingest(bundle([ patient, condition("N18.6", "ESRD") ]))
      assert_equal "Kidney (renal) failure", renal.diagnosis
    end

    test "a RelatedPerson submitter is recorded as family and supplies contact" do
      related = { "resourceType" => "RelatedPerson",
                  "telecom" => [ { "system" => "phone", "value" => "786-555-0199" } ] }
      p = patient("telecom" => nil)   # patient has no contact; RelatedPerson provides it
      i = ingest(bundle([ p, related, condition("G30.9", "Alzheimer's") ]))

      assert_equal "Caregiver or Family Member", i.requester_role
      assert_equal "786-555-0199", i.contact
      assert_equal "Dementia or Alzheimer's", i.diagnosis
    end

    test "creating the inquiry fans out to the on-call coordinator pipeline" do
      assert_enqueued_with(job: InquiryAlertJob) do
        ingest(bundle([ patient, condition("C50.9") ]))
      end
    end

    test "rejects a non-Bundle payload" do
      err = assert_raises(Fhir::ReferralIngest::InvalidBundle) { ingest({ "resourceType" => "Patient" }) }
      assert_match(/not a FHIR Bundle/, err.message)
    end

    test "rejects a bundle with no Patient" do
      assert_raises(Fhir::ReferralIngest::InvalidBundle) { ingest(bundle([ service_request ])) }
    end

    test "rejects a bundle with no contact point" do
      err = assert_raises(Fhir::ReferralIngest::InvalidBundle) do
        ingest(bundle([ patient("telecom" => nil), condition("C34.90") ]))
      end
      assert_match(/no phone or email/, err.message)
    end
  end
end
