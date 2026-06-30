require "test_helper"

class Cms::HospiceCoverageTest < ActiveSupport::TestCase
  test "maps terminal-status diagnoses to their hospice LCD category" do
    {
      "I50.9"   => "Heart Disease — CHF",
      "N18.6"   => "Renal Disease",
      "J44.9"   => "Pulmonary — COPD",
      "G30.9"   => "Alzheimer's / Dementia",
      "C50.911" => "Neoplasms (Cancer)",
      "B20"     => "HIV / AIDS",
      "R64"     => "Adult Failure to Thrive / Debility"
    }.each do |code, lcd|
      r = Cms::HospiceCoverage.call(code)
      assert_equal :likely_covered, r.status, "#{code} should be likely covered"
      assert_equal lcd, r.lcd, code
    end
  end

  test "flags non-terminal diagnoses for review" do
    %w[A09 S72.001A Z51.5].each do |code|
      assert_equal :needs_review, Cms::HospiceCoverage.call(code).status, code
    end
  end

  test "needs review (not a crash) when there is no code" do
    assert_equal :needs_review, Cms::HospiceCoverage.call("").status
    assert_equal :needs_review, Cms::HospiceCoverage.call(nil).status
  end
end
