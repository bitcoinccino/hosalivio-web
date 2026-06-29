require "test_helper"

# A family nurse-timing question auto-flags the patient's visit nurse so they
# reach out with an update — once per window, and only for timing questions.
class HosalivioTimingNotifyTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @nurse   = create_user(agency: @agency, full_name: "Nina Park", roles: %w[rn])
    @patient = create_patient(agency: @agency, assigned_visit_rn: @nurse)
  end

  # Force the brain to no-answer so the deterministic fallback + auto-notify path
  # runs (no live LLM call — keeps the test fast and stable). Capture/override/
  # restore the singleton method directly to avoid a mock dependency.
  def without_llm
    sclass = HosalivioBrain.singleton_class
    orig   = sclass.instance_method(:answer_clinician_question)
    sclass.send(:define_method, :answer_clinician_question) { |*, **| nil }
    yield
  ensure
    sclass.send(:define_method, :answer_clinician_question, orig)
  end

  def ask(body)
    in_tenant(@agency) do
      note = Note.create!(agency: @agency, patient: @patient, author_role: "family",
                          source: "text", body: body, urgency: "normal")
      without_llm { HosalivioTriager.new(note).triage! }
    end
  end

  def nurse_notifications = in_tenant(@agency) { Notification.where(user: @nurse).count }

  test "a timing question auto-notifies the patient's visit nurse" do
    assert_difference -> { nurse_notifications }, 1 do
      ask("When is the nurse coming?")
    end
    # Note bodies are encrypted at rest, so filter in Ruby on the decrypted body.
    note = in_tenant(@agency) do
      @patient.notes.where(clinician_only: true).detect { |n| n.body.to_s.include?("next nurse visit") }
    end
    assert note, "an @-mention nurse note was posted"
    assert_includes note.body, "Nina"
  end

  test "repeated timing questions don't re-ping the nurse (deduped within 2h)" do
    ask("When is the nurse coming?")
    assert_no_difference -> { nurse_notifications } do
      ask("any update on when she's coming?")
    end
  end

  test "a non-timing question does not auto-notify the nurse" do
    assert_no_difference -> { nurse_notifications } do
      ask("How is she feeling today?")
    end
  end
end
