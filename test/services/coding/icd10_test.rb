require "test_helper"

class Coding::Icd10Test < ActiveSupport::TestCase
  setup do
    Icd10Code.create!(code: "I50.9", description: "Heart failure, unspecified")
    Icd10Code.create!(code: "A09",   description: "Infectious gastroenteritis and colitis, unspecified")
  end

  test "validates codes in the index, dot/case-insensitive" do
    assert Coding::Icd10.valid?("I50.9")
    assert Coding::Icd10.valid?("i509"), "dotless + lowercase resolves"
    assert Coding::Icd10.valid?("A09")
    refute Coding::Icd10.valid?("ZZ99")
    refute Coding::Icd10.valid?("")
  end

  test "describe returns the authoritative description" do
    assert_equal "Heart failure, unspecified", Coding::Icd10.describe("I50.9")
    assert_nil Coding::Icd10.describe("ZZ99")
  end
end
