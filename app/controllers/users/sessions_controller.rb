# Devise SessionsController override. We only support the 6-digit email
# code flow for sign-in now — the classic email + password form is
# reachable only by its POST endpoint (Warden/Devise still uses it if
# a client hits it directly), but the `new` page redirects to the
# passwordless flow so the UI never offers a password field.
#
# Leaving :destroy alone so /users/sign_out still logs the user out as
# Devise expects.

class Users::SessionsController < Devise::SessionsController
  def new
    redirect_to new_passwordless_path
  end
end
