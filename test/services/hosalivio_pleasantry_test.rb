require "test_helper"

# A pure "thank you" should get a warm acknowledgment — not the Q&A brain's
# apologetic fallback that also falsely claimed it nudged the team.
class HosalivioPleasantryTest < ActiveSupport::TestCase
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

  def triager
    in_tenant(@agency) { HosalivioTriager.new(family_note("placeholder")) }
  end

  test "pleasantry? recognizes pure gratitude / closers" do
    t = triager
    [ "Thank you!", "thanks so much", "ty", "Appreciate it",
      "thank you very much", "thanks, the nurse was wonderful" ].each do |m|
      assert t.pleasantry?(m), "#{m.inspect} should be a pleasantry"
    end
  end

  test "pleasantry? excludes thanks-with-a-request and questions" do
    t = triager
    [ "thanks, can you send a refill?", "thank you, when is the nurse coming?",
      "thanks but we need more morphine", "thank you for sending the refill this morning please" ].each do |m|
      refute t.pleasantry?(m), "#{m.inspect} should NOT be a pleasantry"
    end
  end

  test "a thank-you gets a warm ack — no Q&A fallback, no team nudge" do
    note = family_note("Thank you!")
    in_tenant(@agency) { HosalivioTriager.new(note).triage! }
    in_tenant(@agency) do
      assert note.reload.read_at.present?, "inbound is marked handled"
      reply = @patient.notes.where(author_role: "admissions", source: "system").order(:created_at).last
      assert_includes reply.body, "You're very welcome"
      refute reply.body.include?("nudged"), "no false 'nudged the team' claim"
      refute reply.clinician_only?, "the ack is family-visible"
      assert_equal 0, AgentEvent.where(subject: @patient, action: "handoff").count, "no handoff fired"
      assert_empty @patient.notes.where(clinician_only: true), "no internal triage note created"
    end
  end
end
