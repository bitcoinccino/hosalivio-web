require "test_helper"

class EventNarratorTest < ActiveSupport::TestCase
  def story_for(agent_id:, action:, subject_type:, change_set: {})
    ev = AgentEvent.new(agent_id: agent_id, action: action, subject_type: subject_type, change_set: change_set)
    EventNarrator::Story.new(event: ev, extra_targets: [], patient_lookup: {})
  end

  test "action_label drops the trailing connector where the patient sat" do
    s = story_for(agent_id: "admissions", action: "create", subject_type: "Note")
    # narrate: "posted a triage update for" → patient-independent label
    assert_equal "posted a triage update", s.action_label
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
