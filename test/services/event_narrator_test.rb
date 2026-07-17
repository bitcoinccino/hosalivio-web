require "test_helper"

class EventNarratorTest < ActiveSupport::TestCase
  def story_for(agent_id:, action:, subject_type:, change_set: {}, merged_count: 1)
    ev = AgentEvent.new(agent_id: agent_id, action: action, subject_type: subject_type, change_set: change_set)
    EventNarrator::Story.new(event: ev, extra_targets: [], patient_lookup: {}, merged_count: merged_count)
  end

  test "action_label drops the trailing connector where the patient sat" do
    s = story_for(agent_id: "triage", action: "create", subject_type: "Note")
    # narrate: "triaged a family message for" → patient-independent label
    assert_equal "triaged a family message", s.action_label
  end

  test "merged triage notes are pluralised" do
    s = story_for(agent_id: "triage", action: "create", subject_type: "Note", merged_count: 3)
    assert_equal "triaged 3 family messages", s.action_label
  end

  test "dispatch is titled Dispatch, not Admissions" do
    # HosAlivio routing a clinician's @-mention request is not admissions work.
    s = story_for(agent_id: "dispatch", action: "handoff", subject_type: "Patient")
    assert_equal "HosAlivio (Dispatch)", s.source_label
  end

  test "family invite names the invitee instead of falling through to the raw action" do
    s = story_for(agent_id: "system", action: "family_user_invited", subject_type: "User",
                  change_set: { "family_full_name" => "Marie Alvarez", "relationship" => "daughter" })
    assert_equal "invited Marie Alvarez (daughter) to the Care Portal", s.action_label
  end

  test "answered family question does not fall through to the raw action" do
    s = story_for(agent_id: "triage", action: "answer_family_question", subject_type: "Patient")
    assert_equal "answered a family question", s.action_label
  end

  test "HosAlivio personas wear the AI icon; people wear their initials" do
    %w[admissions triage dispatch hosalivio_brain system].each do |ai|
      s = story_for(agent_id: ai, action: "create", subject_type: "Note")
      assert_equal EventNarrator::AI_ICON, s.avatar_icon, "#{ai} should wear the AI icon"
    end

    %w[rn md don social_worker chaplain aide front_door_inbound family].each do |human|
      s = story_for(agent_id: human, action: "create", subject_type: "Note")
      assert_nil s.avatar_icon, "#{human} should fall back to initials"
    end
  end

  test "an unknown agent_id falls back to initials rather than the AI icon" do
    s = story_for(agent_id: "some_new_agent", action: "create", subject_type: "Note")
    assert_nil s.avatar_icon
  end

  test "triage persona is titled Triage, not Admissions" do
    s = story_for(agent_id: "triage", action: "create", subject_type: "Note")
    assert_equal "HosAlivio (Triage)", s.source_label
  end

  test "the system agent_id reads as Agent, not System" do
    # "system" is the internal stamp; the feed is read by agency staff, to whom
    # HosAlivio is an agent, not plumbing.
    s = story_for(agent_id: "system", action: "family_user_invited", subject_type: "User")
    assert_equal "HosAlivio (Agent)", s.source_label
  end

  test "a handoff to the visit RN uses the readable role label" do
    ev = AgentEvent.new(agent_id: "triage", action: "handoff", subject_type: "Patient",
                        change_set: { "target_role" => "visit_rn" })
    s  = EventNarrator::Story.new(event: ev, extra_targets: [ "visit_rn", "pharmacy" ], patient_lookup: {})
    assert_equal "assigned to the Visit RN + Pharmacy team", s.action_label
  end

  test "action_label turns a possessive tail into 'the …'" do
    s = story_for(agent_id: "rn", action: "update", subject_type: "Patient")
    # narrate: before "updated", after "'s chart"
    assert_equal "updated the chart", s.action_label
  end

  test "action_label keeps a handoff's target phrase" do
    ev = AgentEvent.new(agent_id: "admissions", action: "handoff", subject_type: "Patient",
                        change_set: { "target_role" => "rn" })
    s  = EventNarrator::Story.new(event: ev, extra_targets: [ "rn" ], patient_lookup: {})
    assert_equal "assigned to the RN team", s.action_label
  end

  test "source_label includes the persona title" do
    s = story_for(agent_id: "admissions", action: "create", subject_type: "Note")
    assert_equal "HosAlivio (Admissions)", s.source_label
  end
end
