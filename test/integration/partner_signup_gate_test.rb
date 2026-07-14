require "test_helper"

# The self-serve partner wizard provisions a live agency, so it's gated:
# only a link carrying a valid onboarding token (sent after the agreement
# is signed) may enter. See PartnersController#require_signup_invite.
class PartnerSignupGateTest < ActionDispatch::IntegrationTest
  def token
    PartnersController.signup_token
  end

  test "an un-invited visitor is shown the invite-required page, not the wizard" do
    get new_partner_path
    assert_response :forbidden
    assert_match "Onboarding is by invitation", response.body
    assert_no_match(/Tell us about your agency/, response.body)   # the step-1 form
  end

  test "a wrong token is rejected" do
    get new_partner_path(token: "not-the-token")
    assert_response :forbidden
    assert_match "Onboarding is by invitation", response.body
  end

  test "a valid token opens the wizard" do
    get new_partner_path(token: token)
    assert_response :success
    assert_match "Tell us about your agency", response.body
  end

  test "authorization persists for the session so later steps need no token" do
    get new_partner_path(token: token)
    assert_response :success
    # Same session, no token echoed — the gate remembers this browser.
    get new_partner_path
    assert_response :success
    assert_match "Tell us about your agency", response.body
  end

  test "POSTing step 1 without ever presenting a token is blocked" do
    post partners_path, params: { legal_name: "Sneaky LLC", slug: "SNEAK" }
    assert_response :forbidden
    assert_match "Onboarding is by invitation", response.body
  end
end
