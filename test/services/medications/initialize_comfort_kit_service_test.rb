require "test_helper"

# Pure-logic tests for the comfort-kit builder — the tamper-resistance is the
# security-critical claim (the server reconstructs drug data from a trusted
# constant, never from client input), so it's worth pinning. Uses unsaved
# records so no fixtures/DB are needed.
class Medications::InitializeComfortKitServiceTest < ActiveSupport::TestCase
  KIT = Medications::InitializeComfortKitService

  def service
    eval_rec = PreAdmitEval.new(patient: Patient.new, agency: Agency.new)
    KIT.new(eval: eval_rec, user: User.new)
  end

  test "suggests all seven kit items as comfort-kit drafts, two controlled" do
    s = service.suggestions
    assert_equal 7, s.size
    assert_equal 2, s.count(&:controlled), "Ativan + Roxanol are the controlled items"
    assert s.all?(&:comfort_kit), "every suggestion is tagged comfort_kit"
    assert s.all?(&:order_draft?), "every suggestion is a draft (no authority yet)"
    assert s.all?(&:prn), "comfort-kit meds are all PRN"
  end

  test "every suggestion maps to real MedicationOrder columns" do
    service.suggestions.each do |o|
      assert o.drug_name.present?
      assert o.dose.present?
      assert o.frequency.present?
      assert MedicationOrder.routes.key?(o.route), "route #{o.route.inspect} is a valid enum"
    end
  end

  test "build_drafts only builds known keys and ignores tampered/unknown ones" do
    built = service.build_drafts(%w[ativan roxanol not_a_real_drug compazine_tab])
    assert_equal 3, built.size, "the bogus key is dropped"
    names = KIT::BASELINE_KIT_ITEMS.map { |i| i[:name] }
    assert built.all? { |o| names.include?(o.drug_name) }, "no injected drug survives"
    refute built.any? { |o| o.drug_name.to_s.include?("not_a_real_drug") }
  end

  test "build_drafts stamps start_date so orders are persist-valid; suggestions don't" do
    assert_nil service.suggestions.first.start_date
    assert_equal Date.current, service.build_drafts(%w[ativan]).first.start_date
  end

  test "empty or all-bogus selections build nothing" do
    assert_empty service.build_drafts([])
    assert_empty service.build_drafts(%w[nope nada])
  end
end
