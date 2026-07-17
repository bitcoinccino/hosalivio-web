require "test_helper"

# "Which humans did HosAlivio wake, and why?" must be answerable from one query.
#
# It wasn't. Two paths escalate — emit_handoff writes an AgentEvent, while
# execute_notify wrote only a Note + Notification — so a real escalation could
# leave no trace in the agent audit trail at all. Reading either source alone
# gave a confidently wrong answer in both directions.
class AgentEventEscalationTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @patient = create_patient(agency: @agency, first_name: "Benworth", last_name: "Zoff")
    @nurse   = create_user(agency: @agency, full_name: "Diaphnie Casimir", roles: %w[rn])
  end

  def handoff!(role: "visit_rn", intent: "med_refill")
    in_tenant(@agency) do
      AgentEvent.create!(agency: @agency, agent_id: "triage", agent_session_id: "s-#{SecureRandom.hex(2)}",
                         action: "handoff", subject: @patient, happened_at: Time.current,
                         change_set: { "target_role" => role, "intent" => intent, "urgency" => "urgent" })
    end
  end

  def notify!(user: nil, role: "visit_rn")
    user ||= @nurse
    in_tenant(@agency) do
      AgentEvent.create!(agency: @agency, agent_id: "triage", agent_session_id: "s-#{SecureRandom.hex(2)}",
                         action: "notify_clinician", subject: @patient, happened_at: Time.current,
                         change_set: { "target_role" => role, "target_user_id" => user.id,
                                       "target_name" => user.full_name, "reason" => "out of morphine" })
    end
  end

  test "escalations covers both mechanisms" do
    in_tenant(@agency) do
      handoff!
      notify!
      # Not escalations — HosAlivio talking, not waking anyone.
      AgentEvent.create!(agency: @agency, agent_id: "triage", agent_session_id: "s1",
                         action: "answer_family_question", subject: @patient, happened_at: Time.current)

      assert_equal 2, AgentEvent.escalations.count,
                   "both the queue path and the named-person path must be queryable together"
      assert_equal %w[handoff notify_clinician].sort, AgentEvent.escalations.map(&:action).sort
    end
  end

  test "an answered question is not an escalation" do
    in_tenant(@agency) do
      AgentEvent.create!(agency: @agency, agent_id: "triage", agent_session_id: "s1",
                         action: "answer_family_question", subject: @patient, happened_at: Time.current)
      assert_empty AgentEvent.escalations, "answering the family wakes nobody"
    end
  end

  test "an escalation reports the role it targeted, whichever path it took" do
    in_tenant(@agency) do
      assert_equal "visit_rn", handoff!(role: "visit_rn").escalated_to_role
      assert_equal "pharmacy", notify!(role: "pharmacy").escalated_to_role
    end
  end

  test "only the notify path names a person — a handoff addresses a queue" do
    in_tenant(@agency) do
      assert_nil handoff!.escalated_to_user_id, "a handoff targets a role's queue, not an individual"
      assert_equal @nurse.id, notify!.escalated_to_user_id
    end
  end

  test "for_patient scopes escalations to one chart" do
    other = create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez")
    in_tenant(@agency) do
      handoff!
      AgentEvent.create!(agency: @agency, agent_id: "triage", agent_session_id: "s2",
                         action: "handoff", subject: other, happened_at: Time.current,
                         change_set: { "target_role" => "md" })

      assert_equal 1, AgentEvent.escalations.for_patient(@patient).count
      assert_equal 1, AgentEvent.escalations.for_patient(other.id).count
    end
  end

  test "the feed names who was woken instead of printing the raw action" do
    ev = in_tenant(@agency) { notify! }
    story = EventNarrator::Story.new(event: ev, extra_targets: [], patient_lookup: {})
    # Regression: notify_clinician had no narrate case and rendered as
    # "notify clinician (patient)". The trailing "with" is stripped by
    # action_label — it's the connector the patient used to sit after.
    assert_equal "flagged Diaphnie Casimir to follow up", story.action_label
  end

  test "a notify with no recorded name falls back to the role label" do
    ev = in_tenant(@agency) do
      AgentEvent.create!(agency: @agency, agent_id: "triage", agent_session_id: "s3",
                         action: "notify_clinician", subject: @patient, happened_at: Time.current,
                         change_set: { "target_role" => "visit_rn" })
    end
    story = EventNarrator::Story.new(event: ev, extra_targets: [], patient_lookup: {})
    assert_equal "flagged Visit RN to follow up", story.action_label
  end
end
