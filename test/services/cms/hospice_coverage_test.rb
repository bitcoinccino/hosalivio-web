require "test_helper"

class Cms::HospiceCoverageTest < ActiveSupport::TestCase
  # Codes map to the real hospice LCD id (resolved from the live-verified set).
  test "maps terminal-status diagnoses to the governing hospice LCD" do
    {
      "I50.9"   => "L34548", # Cardiopulmonary
      "J44.9"   => "L34548",
      "N18.6"   => "L34559", # Renal
      "G30.9"   => "L34567", # Alzheimer's
      "G12.21"  => "L34547", # Neurological (ALS)
      "K74.60"  => "L34544", # Liver
      "R64"     => "L34558", # Adult Failure to Thrive
      "C50.911" => "L34538", # cancer → Determining Terminal Status
      "B20"     => "L34538"  # HIV → Determining Terminal Status
    }.each do |code, lcd_id|
      r = Cms::HospiceCoverage.call(code)
      assert_equal :likely_covered, r.status, code
      assert_equal lcd_id, r.lcd_id, "#{code} should cite #{lcd_id}"
      assert r.lcd_url.to_s.include?(lcd_id.delete("L")), "links to the real LCD"
    end
  end

  test "flags non-terminal diagnoses for review (no LCD)" do
    %w[A09 S72.001A Z51.5].each do |code|
      r = Cms::HospiceCoverage.call(code)
      assert_equal :needs_review, r.status, code
      assert_nil r.lcd_id
    end
  end

  test "needs review (not a crash) when there is no code" do
    assert_equal :needs_review, Cms::HospiceCoverage.call("").status
    assert_equal :needs_review, Cms::HospiceCoverage.call(nil).status
  end
end
