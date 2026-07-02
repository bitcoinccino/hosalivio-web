require "test_helper"

module Coding
  class NpiTest < ActiveSupport::TestCase
    test "is dormant in the test env (offline-safe)" do
      refute Coding::Npi.live_enabled?, "NPPES lookup must never fire in test/CI"
      assert_nil Coding::Npi.lookup(last_name: "Smith", first_name: "John", state: "FL")
    end

    test "builds an individual (NPI-1) query from a name + geo filter" do
      params = Coding::Npi.build_params(first_name: "John", last_name: "Smith",
                                        organization_name: nil, state: "FL", postal_code: "33101")
      assert_equal "NPI-1", params[:enumeration_type]
      assert_equal "Smith", params[:last_name]
      assert_equal "John",  params[:first_name]
      assert_equal "FL",    params[:state]
      assert_equal "33101", params[:postal_code]
    end

    test "builds an organization (NPI-2) query and ignores name fields" do
      params = Coding::Npi.build_params(first_name: nil, last_name: nil,
                                        organization_name: "Sunrise Medical Center", state: nil, postal_code: nil)
      assert_equal "NPI-2", params[:enumeration_type]
      assert_equal "Sunrise Medical Center", params[:organization_name]
    end

    test "returns empty params when there's nothing to search on" do
      assert_empty Coding::Npi.build_params(first_name: nil, last_name: nil, organization_name: nil, state: nil, postal_code: nil)
    end

    test "trusts only a single unambiguous NPPES match" do
      one = {
        "result_count" => 1,
        "results" => [ {
          "number" => "1679567796", "enumeration_type" => "NPI-1",
          "basic" => { "first_name" => "JOHN", "last_name" => "SMITH", "credential" => "DR" },
          "taxonomies" => [ { "desc" => "Dentist", "primary" => true } ]
        } ]
      }
      r = Coding::Npi.parse_single(one)
      assert_equal "1679567796", r["npi"]
      assert_equal "JOHN SMITH", r["name"]
      assert_equal "DR",         r["credential"]
      assert_equal "Dentist",    r["taxonomy"]
    end

    test "declines ambiguous (many), empty, or malformed results" do
      assert_nil Coding::Npi.parse_single("result_count" => 2, "results" => [ {}, {} ])
      assert_nil Coding::Npi.parse_single("result_count" => 0, "results" => [])
      assert_nil Coding::Npi.parse_single(nil)
      assert_nil Coding::Npi.parse_single("result_count" => 1, "results" => [ { "number" => "" } ])
    end

    test "reads an organization name from the basic block" do
      org = { "result_count" => 1, "results" => [ { "number" => "1234567893",
        "basic" => { "organization_name" => "Sunrise Medical Center" } } ] }
      assert_equal "Sunrise Medical Center", Coding::Npi.parse_single(org)["name"]
    end
  end
end
