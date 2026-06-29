require "test_helper"

# The relay-offer nudge: when HosAlivio drafts-and-holds a family-facing reply,
# the patient's responsible RN gets an in-app bell so the held commitment can't
# silently stall. Plus: that bell never fans out to an external ping.
class ClinicianDispatcherRelayOfferTest < ActiveSupport::TestCase
  setup do
    @agency   = create_agency
    @visit_rn = create_user(agency: @agency, full_name: "Vera Visit",  roles: %w[rn])
    @adm_rn   = create_user(agency: @agency, full_name: "Anna Admit",  roles: %w[admissions])
  end

  def make_offer(patient, message: "We've started the comfort-kit refill; your nurse will follow up.")
    in_tenant(@agency) do
      ClinicianDispatcher.post_family_relay_offer(agency: @agency, patient: patient, message: message)
    end
  end

  def notifications_for(user)
    in_tenant(@agency) { Notification.where(user: user).to_a }
  end

  test "nudges the patient's primary (visit) RN with a linked relay_offer_pending bell" do
    patient = create_patient(agency: @agency, assigned_visit_rn: @visit_rn, assigned_rn: @adm_rn)
    note = nil
    assert_difference -> { notifications_for(@visit_rn).size }, 1 do
      note = make_offer(patient)
    end
    n = notifications_for(@visit_rn).last
    assert_equal "relay_offer_pending", n.kind
    assert_equal "Note", n.linked_type
    assert_equal note.id, n.linked_id, "bell deep-links to the offer note (the draft in chat)"
    assert_empty notifications_for(@adm_rn), "admission RN is not nudged when a primary RN exists"
  end

  test "falls back to the admission RN when no primary RN is assigned" do
    patient = create_patient(agency: @agency, assigned_rn: @adm_rn)
    assert_difference -> { notifications_for(@adm_rn).size }, 1 do
      make_offer(patient)
    end
  end

  test "no assigned RN: the offer still posts, nobody is nudged" do
    patient = create_patient(agency: @agency)
    note = nil
    assert_no_difference -> { in_tenant(@agency) { Notification.count } } do
      note = make_offer(patient)
    end
    assert note.present?, "the draft offer is still created"
  end

  test "relay_offer_pending is suppressed from outbound pings; other kinds still ping" do
    patient = create_patient(agency: @agency, assigned_visit_rn: @visit_rn)
    in_tenant(@agency) do
      # A live channel so a normal notification WOULD fan out to a ping.
      @visit_rn.update!(notification_channels: { "telegram" => { "enabled" => true, "chat_id" => "123" } })

      suppressed = Notification.create!(agency: @agency, user: @visit_rn, kind: "relay_offer_pending",
                                        title: "Draft awaiting Send", linked: patient)
      assert_no_difference -> { OutboundPing.count } do
        OutboundPings::Enqueuer.from_notification(suppressed)
      end

      # Control: a non-suppressed kind on the same channel-enabled user does ping.
      normal = Notification.create!(agency: @agency, user: @visit_rn, kind: "mentioned",
                                    title: "You were mentioned", linked: patient)
      assert_difference -> { OutboundPing.count }, 1 do
        OutboundPings::Enqueuer.from_notification(normal)
      end
    end
  end
end
