require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ]

  # Devise/Warden login for system tests (bypasses the passwordless code flow).
  include Warden::Test::Helpers
  Warden.test_mode!

  def sign_in_as(user)
    login_as(user, scope: :user)
  end

  teardown { Warden.test_reset! }
end
