require "test_helper"

# Hardens #58: a family-facing offer is marked at post time (family_offer), so
# pending-offer detection trusts an authoritative flag instead of re-parsing the
# (encrypted) prose every turn. The body heuristic stays as a back-compat fallback.
class HosalivioOfferMarkerTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @patient = create_patient(agency: @agency)
  end

  def triager(inbound = "hi")
    in_tenant(@agency) do
      note = Note.create!(agency: @agency, patient: @patient, author_role: "family",
                          source: "text", body: inbound, urgency: "normal")
      HosalivioTriager.new(note)
    end
  end

  def ai_note(body, family_offer: false)
    in_tenant(@agency) do
      Note.create!(agency: @agency, patient: @patient, author_role: "admissions", source: "system",
                   body: body, urgency: "normal", family_offer: family_offer)
    end
  end

  test "offer_reply? detects an offer question" do
    t = triager
    assert t.offer_reply?("I can flag this. Would you like me to do that?")
    assert t.offer_reply?("Want me to check with the nurse?")
    refute t.offer_reply?("Maria is resting comfortably.")
    refute t.offer_reply?("Would you like that"), "needs a question mark"
  end

  test "pending_family_offer? trusts the persisted flag even with no offer prose" do
    ai_note("I'll take care of that for you.", family_offer: true) # flagged, body has no cue
    assert triager("flag the right person for me, please").pending_family_offer?
  end

  test "pending_family_offer? falls back to the body heuristic for unflagged notes" do
    ai_note("I can flag this for you. Would you like me to do that?", family_offer: false)
    assert triager("yes please").pending_family_offer?
  end

  test "pending_family_offer? is false for a non-offer prior note" do
    ai_note("Maria is resting comfortably.", family_offer: false)
    refute triager("ok").pending_family_offer?
  end

  test "an offer answer is persisted with family_offer: true" do
    inbound = in_tenant(@agency) do
      Note.create!(agency: @agency, patient: @patient, author_role: "family",
                   source: "text", body: "any update?", urgency: "normal")
    end
    # Inject a known offer answer (no live LLM).
    sclass = HosalivioBrain.singleton_class
    orig   = sclass.instance_method(:answer_clinician_question)
    sclass.send(:define_method, :answer_clinician_question) do |*, **|
      { "answer" => "I can check with the nurse. Would you like me to do that?" }
    end
    in_tenant(@agency) { HosalivioTriager.new(inbound).send(:answer_family!) }
    sclass.send(:define_method, :answer_clinician_question, orig)

    posted = in_tenant(@agency) { @patient.notes.where(author_role: "admissions").order(:created_at).last }
    assert posted.family_offer?, "the offer reply is marked at post time"
  end
end
