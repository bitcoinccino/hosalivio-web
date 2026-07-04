require "test_helper"

class Admin::OverviewTest < ActiveSupport::TestCase
  setup do
    @agency = create_agency
    @rn     = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    @maria  = in_tenant(@agency) { create_patient(agency: @agency, first_name: "Maria", last_name: "Gonzalez") }
    @carlos = in_tenant(@agency) { create_patient(agency: @agency, first_name: "Carlos", last_name: "Diaz") }
  end

  def items_for(command)
    Admin::Overview.run(command, @agency)
  end

  def seed_evals
    in_tenant(@agency) do
      PreAdmitEval.create!(agency: @agency, patient: @maria, evaluator: @rn, evaluator_name: "Reggie RN",
                           status: :final, raw_json: { "pre_admit_eval" => {} })
      PreAdmitEval.create!(agency: @agency, patient: @carlos, evaluator: @rn, evaluator_name: "Reggie RN",
                           status: :certified, noe_deadline_at: 2.days.ago, raw_json: { "pre_admit_eval" => {} })
    end
  end

  test "pending_items flattens certifications, NOE overdue, and missing docs" do
    seed_evals
    items   = items_for("pending_items")
    overdue = items.find { |i| i.text.start_with?("NOE overdue") }
    assert items.any? { |i| i.text.include?("awaiting MD certification") }
    assert overdue&.urgent
    assert_includes overdue.text, "Carlos Diaz"
    assert_equal @carlos.id, overdue.patient_id
  end

  test "patients_needing_attention groups reasons per patient" do
    seed_evals
    items = items_for("patients_needing_attention")
    carlos = items.find { |i| i.text.start_with?("Carlos Diaz") }
    assert carlos, "one row per patient with an issue"
    assert_includes carlos.text, "NOE overdue"
    assert carlos.urgent
  end

  test "compliance_status returns a counts summary" do
    seed_evals
    items = items_for("compliance_status")
    assert(items.any? { |i| i.text.include?("NOE overdue") })
    assert(items.any? { |i| i.text.include?("certification blockers") })
  end

  test "new_referrals lists recent inbound inquiries, new leads flagged urgent" do
    in_tenant(@agency) do
      Inquiry.create!(agency: @agency, first_name: "Lena", contact: "305-555-0100", zip: "33101",
                      source_prompt: "fhir_referral", status: :new_lead)
    end
    items = items_for("new_referrals")
    assert items.any?(&:urgent), "a new_lead referral is urgent"
  end

  test "daily_report summarizes today's counts" do
    items = items_for("daily_report")
    assert items.any? { |i| i.text.include?("new referral") }
    assert items.any? { |i| i.text.include?("open priority item") }
  end

  test "empty agency yields no pending items" do
    assert_empty items_for("pending_items")
  end
end
