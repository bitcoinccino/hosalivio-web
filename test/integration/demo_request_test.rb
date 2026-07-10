require "test_helper"

class DemoRequestTest < ActionDispatch::IntegrationTest
  test "new renders the public book-a-demo form" do
    get demo_path
    assert_response :success
    assert_select "form[action=?]", demo_path
    assert_select "input[name=?]", "demo_request[first_name]"
    assert_select "select[name=?]", "demo_request[primary_ehr]"
  end

  test "valid submission persists a lead and shows a thank-you" do
    assert_difference -> { DemoRequest.count }, 1 do
      post demo_path, params: { demo_request: {
        first_name: "Jane", last_name: "Smith",
        work_email: "jane@mercyhospice.com",
        organization: "Mercy Home Hospice",
        phone: "(555) 010-2020", primary_ehr: "Epic",
        referral_source: "Conference or event"
      } }
    end
    follow_redirect!
    assert_response :success
    assert_match(/Thanks, Jane/, response.body)

    lead = DemoRequest.order(:created_at).last
    assert_equal "jane@mercyhospice.com", lead.work_email
    assert_equal "Epic", lead.primary_ehr
    assert lead.ip_address.present?
  end

  test "referral_display uses the free-text when source is Other" do
    lead = DemoRequest.new(referral_source: "Other", referral_other: "A colleague")
    assert_equal "A colleague", lead.referral_display
  end

  test "invalid submission re-renders with errors and saves nothing" do
    assert_no_difference -> { DemoRequest.count } do
      post demo_path, params: { demo_request: {
        first_name: "", last_name: "Smith", work_email: "not-an-email"
      } }
    end
    assert_response :unprocessable_entity
    assert_select "form[action=?]", demo_path
  end

  test "honeypot submission is silently accepted without persisting" do
    assert_no_difference -> { DemoRequest.count } do
      post demo_path, params: {
        company_site: "http://spam.example",
        demo_request: { first_name: "Bot", last_name: "Net", work_email: "bot@spam.example" }
      }
    end
    follow_redirect!
    assert_response :success
  end
end
