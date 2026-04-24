# Universal 6-digit-code sign-in. Available to every user (admin,
# clinician, family) as an alternative to typing a password.
#
# Flow:
#   GET  /users/sign_in_code         → email entry form
#   POST /users/sign_in_code         → generate + email a code, redirect to verify
#   GET  /users/sign_in_code/verify  → code entry form (email in session)
#   POST /users/sign_in_code/verify  → validate code, sign_in via Warden
#
# Security:
#   - Codes are hashed (SHA-256) at rest
#   - 15-min expiry, single-use (consumed on first successful verify)
#   - Requesting a new code invalidates the previous one
#   - Always shows "if the email matches an account, we sent you a code"
#     so the endpoint doesn't leak which emails are registered

class PasswordlessController < ApplicationController
  SESSION_EMAIL_KEY = :passwordless_email

  def new
  end

  def create
    email = params[:email].to_s.strip.downcase
    if email.blank?
      flash.now[:alert] = "Enter your email to continue."
      render :new, status: :unprocessable_entity
      return
    end

    # Stash the email in the session so the verify step knows which
    # account we're validating against, without trusting a hidden form
    # field from the client.
    session[SESSION_EMAIL_KEY] = email

    user = User.find_by(email: email)
    if user&.active
      code = LoginCode.request_for!(user, ip: request.remote_ip)
      LoginCodeMailer.login_code(user: user, code: code).deliver_now
    else
      # Neutral response — pretend we sent a code either way so we don't
      # leak which emails exist.
      Rails.logger.info("[passwordless] suppressed code for #{email} (no user or inactive)")
    end

    redirect_to verify_passwordless_path
  end

  def verify
    redirect_to(new_passwordless_path) and return if session[SESSION_EMAIL_KEY].blank?
    @email = session[SESSION_EMAIL_KEY]
  end

  def consume
    email = session[SESSION_EMAIL_KEY].to_s
    code  = params[:code].to_s.strip
    if email.blank? || code.blank?
      flash.now[:alert] = "Enter the 6-digit code from your email."
      @email = email
      render :verify, status: :unprocessable_entity
      return
    end

    user = User.find_by(email: email)
    row  = user && LoginCode.consume!(user, code)
    unless row
      flash.now[:alert] = "That code is invalid or expired. Request a new one if you need it."
      @email = email
      render :verify, status: :unprocessable_entity
      return
    end

    session.delete(SESSION_EMAIL_KEY)
    sign_in(user, scope: :user)
    flash[:notice] = "Signed in as #{user.full_name}."
    redirect_to after_sign_in_path(user)
  end

  private

  # Send family users back to their patient's chart, everyone else to
  # the dashboard — matches Devise's default redirect behavior in this
  # app.
  def after_sign_in_path(user)
    if user.family_access? && user.patient_id
      patient_path(user.patient_id)
    else
      dashboard_path
    end
  end
end
