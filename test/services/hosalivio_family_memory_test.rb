require "test_helper"

# Family-chat conversation memory:
#   A) the generic triage prompt now carries recent history, and
#   C) a confirmation of a pending HosAlivio offer is routed to the
#      context-aware path even when it doesn't fit the old short-reply gate.
class HosalivioFamilyMemoryTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @patient = create_patient(agency: @agency)
  end

  def family_note(body)
    in_tenant(@agency) do
      Note.create!(agency: @agency, patient: @patient, author_role: "family",
                   source: "text", body: body, urgency: "normal")
    end
  end

  # A HosAlivio (ai-authored) family-visible note.
  def hosalivio_note(body)
    in_tenant(@agency) do
      Note.create!(agency: @agency, patient: @patient, author_role: "admissions",
                   source: "system", body: body, urgency: "normal")
    end
  end

  OFFER = "For Medicaid questions the best step is our insurance team. I can flag this for the right person. Would you like me to do that?".freeze

  # ── A: thread context reaches the classifier prompt ─────────────────
  test "user_prompt includes the conversation when thread_context is passed" do
    note = family_note("Flag the right person for me, please.")
    ctx = [
      { role: "family",    body: "My mother needs medicaid" },
      { role: "hosalivio", body: OFFER }
    ]
    prompt = HosalivioBrain.new(note, thread_context: ctx).send(:user_prompt)
    assert_includes prompt, "CONVERSATION SO FAR"
    assert_includes prompt, "[hosalivio]"
    assert_includes prompt, "Would you like me to do that?"
    assert_includes prompt, "[family] My mother needs medicaid"
  end

  test "user_prompt is unchanged (no context block) when no thread_context — back-compat" do
    note = family_note("hello")
    prompt = HosalivioBrain.new(note).send(:user_prompt)
    refute_includes prompt, "CONVERSATION SO FAR"
  end

  # ── C: pending-offer detection + routing ────────────────────────────
  test "a 7-word affirmative after a pending offer routes to the memory path" do
    hosalivio_note(OFFER)
    reply = family_note("Flag the right person for me, please.")
    t = in_tenant(@agency) { HosalivioTriager.new(reply) }
    assert t.pending_family_offer?,      "the prior AI turn is detected as an offer"
    assert t.responds_to_pending_offer?, "the 7-word 'please' reply is read as a yes"
  end

  test "no pending offer when the prior AI turn wasn't an offer" do
    hosalivio_note("Thanks for letting us know — I've noted it for the team.")
    reply = family_note("Flag the right person for me, please.")
    t = in_tenant(@agency) { HosalivioTriager.new(reply) }
    refute t.pending_family_offer?
    refute t.responds_to_pending_offer?
  end

  test "a brand-new topic after an offer falls through to triage, not the offer path" do
    hosalivio_note(OFFER)
    reply = family_note("We are completely out of her diabetes medication and the pharmacy closed")
    t = in_tenant(@agency) { HosalivioTriager.new(reply) }
    assert t.pending_family_offer?
    refute t.responds_to_pending_offer?, "a new actionable topic must still reach full triage/handoffs"
  end

  test "a bare 'yes please' after an offer also routes (short-reply path)" do
    hosalivio_note(OFFER)
    reply = family_note("yes please")
    t = in_tenant(@agency) { HosalivioTriager.new(reply) }
    assert t.responds_to_pending_offer?
  end
end
