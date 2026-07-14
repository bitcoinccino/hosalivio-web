require "test_helper"

# The self-serve partner wizard provisions a live agency, so it's gated by a
# unique, one-time PartnerInvite: sales sends its link (?token=…) only after
# the agreement is signed, and the token is consumed on completion.
# See PartnersController#require_signup_invite and PartnerInvite.
class PartnerSignupGateTest < ActionDispatch::IntegrationTest
  test "an un-invited visitor is shown the invite-required page, not the wizard" do
    get new_partner_path
    assert_response :forbidden
    assert_match "Onboarding is by invitation", response.body
    assert_no_match(/Tell us about your agency/, response.body)   # the step-1 form
  end

  test "an unknown token is rejected" do
    get new_partner_path(token: "not-a-real-token")
    assert_response :forbidden
    assert_match "Onboarding is by invitation", response.body
  end

  test "a valid, unused invite opens the wizard" do
    invite = PartnerInvite.create!(agency_label: "Mercy Care")
    get new_partner_path(token: invite.token)
    assert_response :success
    assert_match "Tell us about your agency", response.body
  end

  test "authorization persists for the session so later steps need no token" do
    invite = PartnerInvite.create!
    get new_partner_path(token: invite.token)
    assert_response :success
    # Same session, no token echoed — the gate remembers this browser.
    get new_partner_path
    assert_response :success
    assert_match "Tell us about your agency", response.body
  end

  test "an expired invite is rejected with the expiry message" do
    invite = PartnerInvite.create!(expires_at: 1.day.ago)
    get new_partner_path(token: invite.token)
    assert_response :forbidden
    assert_match "expired", response.body
  end

  test "a used invite cannot be reused" do
    agency = create_agency
    invite = PartnerInvite.create!
    invite.consume!(agency)

    get new_partner_path(token: invite.token)
    assert_response :forbidden
    assert_no_match(/Tell us about your agency/, response.body)
  end

  test "POSTing step 1 without an invite is blocked" do
    post partners_path, params: { legal_name: "Sneaky LLC", slug: "SNEAK" }
    assert_response :forbidden
    assert_match "Onboarding is by invitation", response.body
  end
end
