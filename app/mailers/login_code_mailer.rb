# Emails a fresh 6-digit sign-in code to a user who chose to skip
# passwords. Dev uses letter_opener (opens a browser tab with the email);
# prod should wire ActionMailer to real SMTP.
#
# Called from PasswordlessController#create — the plaintext code is
# never stored, so this is the only place the user can see it.

class LoginCodeMailer < ApplicationMailer
  default from: "noreply@hosalivio.com"

  def login_code(user:, code:)
    @user = user
    @code = code
    mail to: user.email,
         subject: "Your HosAlivio sign-in code: #{code}"
  end
end
