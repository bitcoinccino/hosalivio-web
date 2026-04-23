module MicHelper
  # Picks the right Stimulus controller for voice dictation based on the
  # agency's feature flags. Whisper requires OPENAI_API_KEY and a BAA.
  # Everyone else gets the free, on-device browser Web Speech API.
  #
  #   <% mic = mic_controller_name(current_user.agency) %>
  #   <div data-controller="<%= mic %>" data-<%= mic %>-lang-value="<%= lang %>">
  #     <textarea data-<%= mic %>-target="output"></textarea>
  #     <button data-<%= mic %>-target="button" data-action="click-><%= mic %>#toggle">
  #   </div>
  def mic_controller_name(agency)
    if agency&.feature_enabled?(:whisper_transcription) && ENV["OPENAI_API_KEY"].to_s.strip.present?
      "whisper-dictation"
    else
      "dictation"
    end
  end

  def mic_provider_label(agency)
    agency&.feature_enabled?(:whisper_transcription) ? "Whisper (multilingual)" : "Browser voice (English-first)"
  end
end
