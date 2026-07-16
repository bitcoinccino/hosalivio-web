require "test_helper"

class FollowUpDueSweepJobTest < ActiveSupport::TestCase
  setup do
    @agency = create_agency
    @coord  = create_user(agency: @agency, full_name: "Casey Coordinator", roles: %w[admissions])
    in_tenant(@agency) { @coord.update!(on_call: true) }
  end

  def considering_inquiry(follow_up_at:, first_name: "Pat")
    in_tenant(@agency) do
      Inquiry.create!(agency: @agency, first_name: first_name, contact: "family@example.com",
                      zip: "33101", source_prompt: "nurse_24_7", is_general: true,
                      routed_to_role: "admissions", status: :considering, follow_up_at: follow_up_at)
    end
  end

  def alerts_for(inquiry)
    in_tenant(@agency) do
      Notification.where(kind: FollowUpDueSweepJob::KIND, linked_type: "Inquiry", linked_id: inquiry.id).count
    end
  end

  test "alerts the on-call coordinator when a follow-up has come due" do
    due = considering_inquiry(follow_up_at: 1.day.ago)
    FollowUpDueSweepJob.perform_now
    assert_equal 1, alerts_for(due)
  end

  test "does not alert for a follow-up still in the future" do
    upcoming = considering_inquiry(follow_up_at: 3.days.from_now)
    FollowUpDueSweepJob.perform_now
    assert_equal 0, alerts_for(upcoming)
  end

  test "does not alert for non-considering leads" do
    contacted = in_tenant(@agency) do
      Inquiry.create!(agency: @agency, first_name: "Lee", contact: "x@example.com", zip: "33101",
                      source_prompt: "nurse_24_7", is_general: true, routed_to_role: "admissions",
                      status: :contacted, follow_up_at: 2.days.ago)
    end
    FollowUpDueSweepJob.perform_now
    assert_equal 0, alerts_for(contacted)
  end

  test "is idempotent within a day but re-nudges on a later day" do
    due = considering_inquiry(follow_up_at: 1.day.ago)

    FollowUpDueSweepJob.perform_now
    FollowUpDueSweepJob.perform_now            # same day → no second alert
    assert_equal 1, alerts_for(due)

    # Simulate the previous alert landing yesterday; the next sweep re-nudges.
    in_tenant(@agency) do
      Notification.where(kind: FollowUpDueSweepJob::KIND, linked_id: due.id)
                  .update_all(created_at: 1.day.ago)
    end
    FollowUpDueSweepJob.perform_now
    assert_equal 2, alerts_for(due)
  end

  test "falls back to all admissions coordinators when nobody is on call" do
    in_tenant(@agency) { @coord.update!(on_call: false) }
    due = considering_inquiry(follow_up_at: 1.day.ago)
    FollowUpDueSweepJob.perform_now
    assert_equal 1, alerts_for(due)
  end
end
