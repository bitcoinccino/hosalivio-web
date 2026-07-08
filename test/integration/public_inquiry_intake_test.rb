require "test_helper"

# The public "Request a callback" form posts a full, encrypted intake lead.
class PublicInquiryIntakeTest < ActionDispatch::IntegrationTest
  setup do
    @agency = create_agency(name: "House Hospice", slug: "HOS")
    @agency.update!(is_partner: true)
  end

  def last_inquiry
    ActsAsTenant.with_tenant(@agency) { Inquiry.order(:created_at).last }
  end

  test "persists the full intake as an encrypted lead and composes contact from the phone" do
    assert_difference -> { ActsAsTenant.with_tenant(@agency) { Inquiry.count } }, 1 do
      post inquiries_path, as: :json, params: {
        first_name:      "Maria",
        last_name:       "Gonzalez",
        requester_role:  "Caregiver or Family Member",
        caregiver_phone: "305-555-0100",
        email:           "maria@example.com",
        dob:             "1940-03-02",
        diagnosis:       "Cancer",
        zip:             "33101"
      }
    end
    assert_response :created

    i = last_inquiry
    assert_equal "Maria",                       i.first_name
    assert_equal "Gonzalez",                    i.last_name
    assert_equal "Caregiver or Family Member",  i.requester_role
    assert_equal "305-555-0100",                i.caregiver_phone
    assert_equal "maria@example.com",           i.email
    assert_equal "1940-03-02",                  i.dob
    assert_equal "Cancer",                      i.diagnosis
    assert_equal "33101",                       i.zip
    assert_equal "305-555-0100",                i.contact, "contact stays canonical (phone preferred)"
  end

  test "falls back to email for contact when no phone is given" do
    post inquiries_path, as: :json, params: {
      first_name: "Sam", last_name: "Lee", email: "sam@example.com", zip: "33101"
    }
    assert_response :created
    assert_equal "sam@example.com", last_inquiry.contact
  end

  test "rejects a diagnosis outside the catalog" do
    post inquiries_path, as: :json, params: {
      first_name: "Sam", last_name: "Lee", caregiver_phone: "305-555-0101",
      diagnosis: "Not a real category", zip: "33101"
    }
    assert_response :unprocessable_entity
  end

  test "captures a book-a-call preferred window and exposes a human label" do
    post inquiries_path, as: :json, params: {
      first_name: "Rosa", last_name: "Diaz", caregiver_phone: "305-555-0102", zip: "33101",
      preferred_date: "2026-07-09", preferred_slot: "afternoon"
    }
    assert_response :created
    i = last_inquiry
    assert_equal Date.new(2026, 7, 9), i.preferred_date
    assert_equal "afternoon",          i.preferred_slot
    assert_equal "Thu, Jul 9 · 1-3 PM", i.preferred_window_label
  end

  test "rejects a preferred_slot outside the catalog" do
    post inquiries_path, as: :json, params: {
      first_name: "Rosa", last_name: "Diaz", caregiver_phone: "305-555-0103", zip: "33101",
      preferred_slot: "midnight"
    }
    assert_response :unprocessable_entity
  end
end
