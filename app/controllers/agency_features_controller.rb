class AgencyFeaturesController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_admin!

  PRIVILEGED_ROLES = %w[admin don admissions ceo].freeze

  def edit
    @agency = current_user.agency
  end

  def update
    @agency  = current_user.agency
    enabled  = ActiveModel::Type::Boolean.new.cast(params.dig(:features, :whisper_transcription, :enabled))
    baa_on   = params.dig(:features, :whisper_transcription, :baa_signed_on).presence
    provider = params.dig(:features, :whisper_transcription, :provider).presence || "openai"

    if enabled
      @agency.enable_feature!(:whisper_transcription,
                              provider: provider,
                              baa_signed_on: baa_on)
      flash[:notice] = "Whisper enabled for #{@agency.name}. BAA on file: #{baa_on || 'not specified'}."
    else
      @agency.disable_feature!(:whisper_transcription)
      flash[:notice] = "Whisper disabled. Reverted to free browser voice (Web Speech API)."
    end

    # Telegram replies (two-way bridge). Disabled by default because
    # Telegram is not BAA-covered; the toggle in the UI carries an
    # explicit HIPAA acknowledgement banner.
    tg_enabled = ActiveModel::Type::Boolean.new.cast(params.dig(:features, :allow_telegram_replies))
    features = @agency.features.is_a?(Hash) ? @agency.features.dup : {}
    features["allow_telegram_replies"] = tg_enabled
    @agency.update!(features: features)

    redirect_to edit_agency_features_path, status: :see_other
  end

  private

  def authorize_admin!
    return if (current_user.role_names & PRIVILEGED_ROLES).any?
    redirect_to dashboard_path, alert: "Only admins can change agency features."
  end
end
