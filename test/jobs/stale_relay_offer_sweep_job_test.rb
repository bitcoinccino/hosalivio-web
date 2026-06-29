require "test_helper"

# A held family-relay offer left unsent past the window escalates to the DON.
class StaleRelayOfferSweepJobTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @don     = create_user(agency: @agency, full_name: "Dana DON", roles: %w[don])
    @rn      = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    @patient = create_patient(agency: @agency, assigned_visit_rn: @rn)
  end

  def post_offer
    in_tenant(@agency) do
      ClinicianDispatcher.post_family_relay_offer(
        agency: @agency, patient: @patient,
        message: "We've started the comfort-kit refill; your nurse will follow up."
      )
    end
  end

  # Post an offer and age it past the stale window (both the note and its
  # RN-nudge notification, which is the sweep's worklist).
  def stale_offer
    offer = post_offer
    in_tenant(@agency) do
      offer.update_column(:created_at, 1.hour.ago)
      Notification.where(kind: "relay_offer_pending", linked: offer).update_all(created_at: 1.hour.ago)
    end
    offer
  end

  def don_escalations
    in_tenant(@agency) { Notification.where(user: @don, kind: "relay_offer_escalated").count }
  end

  test "escalates a stale, still-pending offer to the DON" do
    offer = stale_offer
    assert_difference -> { don_escalations }, 1 do
      StaleRelayOfferSweepJob.perform_now
    end
    note = in_tenant(@agency) { Notification.where(user: @don, kind: "relay_offer_escalated").last }
    assert_equal offer.id, note.linked_id, "bell deep-links to the offer"
  end

  test "does not escalate the same offer twice" do
    stale_offer
    StaleRelayOfferSweepJob.perform_now
    assert_no_difference -> { don_escalations } do
      StaleRelayOfferSweepJob.perform_now
    end
  end

  test "does not escalate a fresh offer still inside the window" do
    post_offer # created now, not aged
    assert_no_difference -> { don_escalations } do
      StaleRelayOfferSweepJob.perform_now
    end
  end

  test "does not escalate once the offer is resolved (a newer AI note exists)" do
    stale_offer
    in_tenant(@agency) do
      Note.create!(agency: @agency, patient: @patient, author_role: "admissions", source: "system",
                   clinician_only: false, body: "Sent to the family. They've been notified.", urgency: "normal")
    end
    assert_no_difference -> { don_escalations } do
      StaleRelayOfferSweepJob.perform_now
    end
  end
end
