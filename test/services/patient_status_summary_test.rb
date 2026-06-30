require "test_helper"

# Deterministic, LLM-free chart summary used when the answer brain is down.
class PatientStatusSummaryTest < ActiveSupport::TestCase
  setup do
    @agency = create_agency
    @rn     = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
  end

  test "summarizes code status, diagnosis, unassigned roles, and empty visits/meds" do
    patient = create_patient(agency: @agency, assigned_rn: @rn) # no MD / visit RN
    s = in_tenant(@agency) do
      patient.update!(code_status: "dnr", primary_diagnosis: "CHF (I50.9)")
      PatientStatusSummary.call(patient: patient, role: "rn")
    end
    assert_includes s, patient.full_name
    assert_includes s, "DNR"
    assert_includes s, "CHF (I50.9)"
    assert_includes s, "Admission RN Reggie RN"
    assert_includes s, "MD ⚠ unassigned"
    assert_includes s, "Visits: none on record"
    assert_includes s, "Active meds: none on record"
  end

  test "shows the admission eval status" do
    patient = create_patient(agency: @agency, assigned_rn: @rn)
    s = in_tenant(@agency) do
      create_eval(agency: @agency, patient: patient, evaluator: @rn) # draft
      PatientStatusSummary.call(patient: patient, role: "rn")
    end
    assert_includes s, "Admission eval: draft"
  end

  test "summary_question? detects status asks and rejects commands" do
    assert ClinicianDispatcher.summary_question?("@HosAlivio summarize Maria's status")
    assert ClinicianDispatcher.summary_question?("catch me up on Maria")
    assert ClinicianDispatcher.summary_question?("what's the status?")
    refute ClinicianDispatcher.summary_question?("order morphine 5mg")
    refute ClinicianDispatcher.summary_question?("let the MD know she's declining")
  end

  test "answer_question falls back to the deterministic summary when the brain is down" do
    patient = create_patient(agency: @agency, assigned_rn: @rn)
    note = in_tenant(@agency) do
      Note.create!(agency: @agency, patient: patient, author_user: @rn, author_role: "rn",
                   body: "@HosAlivio summarize this patient's status", source: "text", clinician_only: true)
    end
    # Force the brain to "down".
    sclass = HosalivioBrain.singleton_class
    orig   = sclass.instance_method(:answer_clinician_question)
    sclass.send(:define_method, :answer_clinician_question) { |*, **| nil }
    in_tenant(@agency) { ClinicianDispatcher.new(note, @rn).send(:answer_question) }
    sclass.send(:define_method, :answer_clinician_question, orig)

    posted = in_tenant(@agency) { patient.notes.where(author_role: "admissions").order(:created_at).last }
    assert posted, "a HosAlivio answer was posted"
    assert_includes posted.body, "straight from the chart", "posted the deterministic summary, not an apology"
  end
end
