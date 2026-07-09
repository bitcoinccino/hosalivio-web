require "test_helper"

class SignOutFlashTest < ActionDispatch::IntegrationTest
  test "signing out shows no 'Signed out successfully' flash" do
    agency = create_agency
    user   = create_user(agency: agency, full_name: "Ada Admin", roles: %w[admin])
    sign_in user
    delete destroy_user_session_path
    follow_redirect!
    assert_response :success
    assert_no_match(/Signed out successfully/, response.body)
  end
end
