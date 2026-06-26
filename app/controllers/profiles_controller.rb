class ProfilesController < ApplicationController
  before_action :authenticate_user!

  # Self-serve profile editing. Admin-gated fields (license, caseload,
  # on_call) are read-only here — only the DON can change those via
  # /team_members to preserve oversight.
  def edit
    @user = current_user
  end

  def update
    @user = current_user
    if @user.update(profile_params)
      flash[:notice] = "Profile updated."
      redirect_to edit_profile_path
    else
      flash.now[:alert] = @user.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  def remove_avatar
    current_user.avatar.purge if current_user.avatar.attached?
    redirect_to edit_profile_path, notice: "Profile photo removed."
  end

  # GET /profile/signature — canvas-pad page where the clinician
  # draws their e-signature once. Once saved the chart's "Apply my
  # signature" checkbox unlocks; until then sign-off forms render
  # the inline "Sign now" fallback so the workflow never dead-ends.
  def edit_signature
    @user = current_user
  end

  # PATCH /profile/signature — accepts a base64 data URL the
  # signature_pad client emits (e.g. "data:image/png;base64,iVBOR…")
  # and attaches it as a PNG. Stamps `signature_registered_at` so
  # downstream UIs can tell registered-vs-not without re-fetching
  # the blob. Caller hits this without page reload via fetch.
  def update_signature
    data_url = params.require(:user).permit(:signature_data_url).fetch(:signature_data_url, "").to_s
    if data_url.blank? || !data_url.start_with?("data:image/")
      return render(json: { error: "No signature provided." }, status: :unprocessable_entity)
    end

    encoded = data_url.split(",", 2).last.to_s
    bytes   = Base64.decode64(encoded)
    if bytes.bytesize > User::SIGNATURE_MAX_BYTES
      return render(json: { error: "Signature image is too large." }, status: :unprocessable_entity)
    end

    current_user.signature.attach(
      io:           StringIO.new(bytes),
      filename:     "signature-#{current_user.id}.png",
      content_type: "image/png"
    )
    current_user.update!(signature_registered_at: Time.current)
    render json: {
      ok:                       true,
      signature_url:            url_for(current_user.signature),
      signature_registered_at:  current_user.signature_registered_at.iso8601
    }
  end

  def remove_signature
    current_user.signature.purge if current_user.signature.attached?
    current_user.update!(signature_registered_at: nil)
    redirect_to signature_profile_path, notice: "Signature removed."
  end

  # POST /profile/notifications/test — queues a "Test from HosAlivio"
  # ping on the requested channel so the clinician can verify the
  # integration before going on-call. Drops onto the same OutboundPing
  # queue the rest of the system uses; the openclaw poller delivers
  # within a minute. Returns 422 if the channel isn't enabled or has
  # no contact info filled in (would silently no-op otherwise).
  def test_notification
    channel = params[:channel].to_s
    unless User::CHANNEL_KEYS.include?(channel)
      return render(json: { error: "Unknown channel." }, status: :unprocessable_entity)
    end
    unless current_user.channel_enabled?(channel)
      return render(json: { error: "Toggle the channel on first, then save." }, status: :unprocessable_entity)
    end

    cfg = current_user.notification_channel(channel)
    needs_contact = case channel
    when "telegram" then cfg["chat_id"].to_s.presence.nil?
    when "whatsapp", "sms" then cfg["phone"].to_s.presence.nil?
    else false
    end
    if needs_contact
      return render(json: { error: "Add a contact value and save before testing." }, status: :unprocessable_entity)
    end

    OutboundPing.create!(
      agency:  current_user.agency,
      user:    current_user,
      kind:    "test",
      preview: "Test from HosAlivio · if you can read this, your #{channel} integration is working.",
      payload: { source: "profile_test", channel: channel }
    )
    render json: { ok: true, message: "Test ping queued — it should arrive within a minute." }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  # Self-editable fields. The DON owns service_zips, quiet_hours,
  # license, caseload, and on_call rotation — those flow through
  # /team_members so we strip them here even if a crafted form sneaks
  # them into the payload. NPI is self-set by MDs (it's their personal
  # credential, not an agency assignment).
  def profile_params
    base = %i[full_name email phone_number timezone avatar]
    base += %i[npi] if (current_user.role_names & %w[md]).any?
    permitted = params.require(:user).permit(
      *base,
      notification_channels: [
        { telegram:  [ :enabled, :chat_id ] },
        { whatsapp:  [ :enabled, :phone ] },
        { sms:       [ :enabled, :phone ] },
        { email:     [ :enabled ] }
      ]
    )

    # Merge channel toggles into the canonical shape; preserve the
    # DON-managed `quiet_hours` block untouched so a profile save
    # doesn't blank the schedule the DON set.
    if permitted.key?(:notification_channels)
      raw      = permitted[:notification_channels].to_h
      existing = current_user.notification_channels.is_a?(Hash) ? current_user.notification_channels : {}
      merged   = User::CHANNEL_KEYS.each_with_object({}) do |k, acc|
        sub = raw[k.to_s] || raw[k.to_sym] || {}
        acc[k] = {
          "enabled" => ActiveModel::Type::Boolean.new.cast(sub["enabled"] || sub[:enabled]) || false,
          "chat_id" => sub["chat_id"].to_s.presence,
          "phone"   => sub["phone"].to_s.presence
        }.compact
      end
      merged["quiet_hours"] = existing["quiet_hours"] if existing["quiet_hours"].present?
      permitted[:notification_channels] = merged
    end
    permitted
  end
end
