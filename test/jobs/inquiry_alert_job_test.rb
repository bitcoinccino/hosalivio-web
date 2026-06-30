require "test_helper"

# A public callback request (Inquiry) pages the on-call admissions coordinator
# in the receiving agency via an in-app Notification (which itself fans out to
# the recipient's preferred channel).
class InquiryAlertJobTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @agency = create_agency
  end

  def create_inquiry(agency: @agency, zip: "33101", contact: "family@example.com", first_name: "Pat")
    in_tenant(agency) do
      Inquiry.create!(
        agency: agency, first_name: first_name, contact: contact, zip: zip,
        source_prompt: "nurse_24_7", is_general: true, routed_to_role: "admissions"
      )
    end
  end

  def callback_alerts(user)
    in_tenant(@agency) do
      Notification.where(user: user, kind: InquiryAlertJob::KIND).count
    end
  end

  test "pages the on-call admissions coordinator, and nobody else" do
    on_call    = create_user(agency: @agency, full_name: "Casey Coordinator", roles: %w[admissions])
    in_tenant(@agency) { on_call.update!(on_call: true) }
    off_call   = create_user(agency: @agency, full_name: "Olivia OffCall",     roles: %w[admissions])
    on_call_rn = create_user(agency: @agency, full_name: "Reggie RN",          roles: %w[rn])
    in_tenant(@agency) { on_call_rn.update!(on_call: true) }

    inquiry = create_inquiry
    InquiryAlertJob.perform_now(inquiry.id, @agency.id)

    assert_equal 1, callback_alerts(on_call),    "on-call admissions coordinator is paged"
    assert_equal 0, callback_alerts(off_call),   "off-call admissions coordinator is not paged"
    assert_equal 0, callback_alerts(on_call_rn), "an on-call RN is the wrong role"

    note = in_tenant(@agency) { Notification.where(user: on_call, kind: InquiryAlertJob::KIND).last }
    assert_equal inquiry.id, note.linked_id, "bell deep-links to the inquiry"
  end

  test "falls back to all admissions coordinators when nobody is on-call" do
    a = create_user(agency: @agency, full_name: "Admissions A", roles: %w[admissions])
    b = create_user(agency: @agency, full_name: "Admissions B", roles: %w[admissions])

    inquiry = create_inquiry
    InquiryAlertJob.perform_now(inquiry.id, @agency.id)

    assert_equal 1, callback_alerts(a)
    assert_equal 1, callback_alerts(b)
  end

  test "is idempotent — a coordinator is not paged twice for the same inquiry" do
    user = create_user(agency: @agency, full_name: "Casey Coordinator", roles: %w[admissions])
    in_tenant(@agency) { user.update!(on_call: true) }

    inquiry = create_inquiry
    InquiryAlertJob.perform_now(inquiry.id, @agency.id)
    InquiryAlertJob.perform_now(inquiry.id, @agency.id)

    assert_equal 1, callback_alerts(user)
  end

  test "creating an inquiry enqueues the alert job" do
    assert_enqueued_with(job: InquiryAlertJob) do
      create_inquiry
    end
  end
end
