class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Let Devise accept our custom User fields on sign-up / account edit.
  before_action :configure_permitted_parameters, if: :devise_controller?
  before_action :touch_current_user_presence

  protected

  def configure_permitted_parameters
    devise_parameter_sanitizer.permit(:sign_up,        keys: [:full_name])
    devise_parameter_sanitizer.permit(:account_update, keys: [:full_name])
  end

  def touch_current_user_presence
    return unless respond_to?(:user_signed_in?) && user_signed_in?
    current_user.mark_seen!
  end
end
