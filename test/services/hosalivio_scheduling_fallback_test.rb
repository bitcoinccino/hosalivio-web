require "test_helper"

# Scheduling/timing questions ("When is the nurse coming?") must get a warm,
# honest answer that offers to check — never the generic evasive fallback.
class HosalivioSchedulingFallbackTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @patient = create_patient(agency: @agency, first_name: "Maria")
  end

  def triager
    in_tenant(@agency) do
      note = Note.create!(agency: @agency, patient: @patient, author_role: "family",
                          source: "text", body: "x", urgency: "normal")
      HosalivioTriager.new(note)
    end
  end

  test "scheduling questions get an offer-to-check fallback, not the generic one" do
    t = triager
    [ "When is the nurse coming?", "what time today?", "is someone coming today?",
      "how long until the nurse arrives?", "is she on her way?" ].each do |q|
      ans = t.send(:fallback_answer_for, q)
      assert_includes ans, "check with the nurse", "#{q.inspect} → scheduling fallback"
      assert_includes ans, "Would you like me to do that?", "ends with an offer a yes can act on"
    end
  end

  test "non-scheduling questions still get the generic re-engagement" do
    t = triager
    ans = t.send(:fallback_answer_for, "Does she need anything from us?")
    assert_includes ans, "tell me a little more"
    assert_includes ans, "Maria"
  end

  test "the answer prompt instructs how to handle scheduling/timing questions" do
    assert_includes HosalivioBrain::ANSWER_SYSTEM_PROMPT, "SCHEDULING / TIMING"
    assert_includes HosalivioBrain::ANSWER_SYSTEM_PROMPT, "check with the nurse"
  end
end
