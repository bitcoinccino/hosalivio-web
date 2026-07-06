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
end
