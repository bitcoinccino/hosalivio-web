require "test_helper"

class BranchTest < ActiveSupport::TestCase
  setup { @agency = create_agency }

  def build(**attrs)
    Branch.new(agency: @agency, name: "Orlando", timezone: "America/New_York", **attrs)
  end

  test "service-area ZIP tags are trimmed, de-duped, and blanks dropped" do
    in_tenant(@agency) do
      b = build(service_area_zips: [ "", "328", " 32801 ", "32801" ])
      b.save!
      assert_equal %w[328 32801], b.service_area_zips
    end
  end

  test "a comma-separated string still normalizes (backward compatible)" do
    in_tenant(@agency) do
      b = build(service_area_zips: "328, 32801, 32801")
      b.save!
      assert_equal %w[328 32801], b.service_area_zips
    end
  end

  test "rejects a non-ZIP service-area tag" do
    in_tenant(@agency) do
      b = build(service_area_zips: [ "32801", "abc" ])
      assert_not b.valid?
      assert_match "3- or 5-digit", b.errors[:service_area_zips].to_sentence
    end
  end

  test "county tags keep multi-word names" do
    in_tenant(@agency) do
      b = build(name: "PB", service_area_counties: [ "Palm Beach", "Orange", "" ])
      b.save!
      assert_equal [ "Palm Beach", "Orange" ], b.service_area_counties
    end
  end

  test "levels of care keep only known keys, in canonical order, and drop blanks" do
    in_tenant(@agency) do
      # submitted out of order, with the form's blank and an unknown value
      b = build(levels_of_care: [ "", "respite", "bogus", "routine_home" ])
      b.save!
      assert_equal %w[routine_home respite], b.levels_of_care
      assert b.offers_level?(:respite)
      assert_not b.offers_level?(:gip)
      assert_equal [ "Routine Home Care", "Inpatient Respite" ], b.levels_of_care_labels
      assert_equal [ "Routine", "Respite" ], b.levels_of_care_badges
    end
  end

  test "levels of care default to an empty array" do
    in_tenant(@agency) do
      b = build
      b.save!
      assert_equal [], b.levels_of_care
      assert_equal [], b.levels_of_care_badges
    end
  end
end
