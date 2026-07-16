require "test_helper"

class InquiryConsideringTest < ActionDispatch::IntegrationTest
  def build_inquiry(agency:, first_name: "Pat")
    in_tenant(agency) do
      Inquiry.create!(agency: agency, first_name: first_name, contact: "family@example.com",
                      zip: "33101", source_prompt: "nurse_24_7", is_general: true,
                      routed_to_role: "admissions", status: :contacted)
    end
  end

  test "deferring a lead parks it as considering with a follow-up date" do
    agency  = create_agency
    admin   = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])
    inquiry = build_inquiry(agency: agency)

    sign_in admin
    post defer_inquiry_path(inquiry), params: { follow_up_in_days: 7 }
    assert_response :redirect

    inquiry.reload
    assert inquiry.status_considering?
    assert inquiry.follow_up_at.present?
    assert_in_delta 7.days.from_now.to_i, inquiry.follow_up_at.to_i, 60
    refute inquiry.follow_up_due?   # future date → not due yet
  end

  test "an explicit follow_up_at date is honored and a past date reads as due" do
    agency  = create_agency
    admin   = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])
    inquiry = build_inquiry(agency: agency)

    sign_in admin
    post defer_inquiry_path(inquiry), params: { follow_up_at: 2.days.ago.to_date.iso8601 }
    inquiry.reload
    assert inquiry.status_considering?
    assert inquiry.follow_up_due?   # past date → surfaces as a due follow-up
  end

  test "the considering filter lists parked leads and the inbox counts follow-ups due" do
    agency  = create_agency
    admin   = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])
    parked  = build_inquiry(agency: agency, first_name: "Wanda")

    sign_in admin
    post defer_inquiry_path(parked), params: { follow_up_at: 1.day.ago.to_date.iso8601 }

    get inquiries_path(status: "considering")
    assert_response :success
    assert_match "Wanda", response.body
    assert_match "Considering", response.body

    get inquiries_path
    assert_match "follow-up", response.body   # the "N follow-ups due" indicator
  end
end
