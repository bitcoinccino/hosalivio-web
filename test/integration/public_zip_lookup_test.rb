require "test_helper"

class PublicZipLookupTest < ActionDispatch::IntegrationTest
  test "ZIP lookup finds a partner branch by service-area prefix" do
    ActsAsTenant.without_tenant do
      agency = create_agency(name: "Sunshine Hospice")
      agency.update!(is_partner: true, accepting_referrals: true, active: true)
      Branch.create!(agency: agency, name: "Orlando", timezone: "America/New_York",
                     active: true, service_area_zips: [ "328" ])   # 3-digit prefix
    end

    # 32801 falls under prefix 328 — matched via jsonb string containment.
    get public_chat_agencies_path, params: { zip: "32801" }
    assert_response :success
    names = JSON.parse(response.body)["agencies"].map { |c| c["agency_name"] }
    assert_includes names, "Sunshine Hospice"
  end

  test "exact-ZIP matches are ordered before 3-digit-prefix matches" do
    ActsAsTenant.without_tenant do
      # Alphabetically "Zeta" < "Zulu", so name order alone would put the prefix
      # agency first — the exact-ZIP one should win regardless.
      prefix_a = create_agency(name: "Zeta Prefix Hospice")
      prefix_a.update!(is_partner: true, accepting_referrals: true, active: true)
      Branch.create!(agency: prefix_a, name: "Reg", timezone: "America/New_York",
                     active: true, service_area_zips: [ "328" ])

      exact_a = create_agency(name: "Zulu Exact Hospice")
      exact_a.update!(is_partner: true, accepting_referrals: true, active: true)
      Branch.create!(agency: exact_a, name: "Local", timezone: "America/New_York",
                     active: true, service_area_zips: [ "32801" ])
    end

    get public_chat_agencies_path, params: { zip: "32801" }
    names = JSON.parse(response.body)["agencies"].map { |c| c["agency_name"] }
    assert_equal [ "Zulu Exact Hospice", "Zeta Prefix Hospice" ], names
  end

  test "non-partner agencies are not surfaced to the public chat" do
    ActsAsTenant.without_tenant do
      agency = create_agency(name: "Internal Only")
      agency.update!(is_partner: false, accepting_referrals: true, active: true)
      Branch.create!(agency: agency, name: "Hub", timezone: "America/New_York",
                     active: true, zip: "32801", service_area_zips: [ "32801" ])
    end

    get public_chat_agencies_path, params: { zip: "32801" }
    assert_response :success
    names = JSON.parse(response.body)["agencies"].map { |c| c["agency_name"] }
    assert_not_includes names, "Internal Only"
  end
end
