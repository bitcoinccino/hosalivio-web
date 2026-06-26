require "net/http"
require "uri"
require "securerandom"

# Thin wrapper around OpenAI's Whisper API (model: whisper-1).
# Input: a Rack uploaded file (from multipart form) + optional language hint.
# Output: a Result struct with :ok?, :text, :duration_seconds, :error.
#
# When OPENAI_API_KEY is missing, returns a friendly no-key error without
# raising — this keeps the family chat functional even with Whisper turned
# off and lets the UI degrade to the browser Web Speech API.
#
# Billing: whisper-1 costs $0.006/min of audio as of early 2026. The service
# logs each call with estimated cost so the operator can audit spend.
class WhisperTranscriber
  API_URL     = "https://api.openai.com/v1/audio/transcriptions"
  MODEL       = "whisper-1"
  PRICE_PER_MINUTE = 0.006
  MAX_BYTES   = 25 * 1024 * 1024 # 25MB OpenAI limit

  Result = Struct.new(:ok?, :text, :duration_seconds, :cost_usd, :error, keyword_init: true)

  def self.call(audio:, language: nil, prompt: nil)
    new(audio: audio, language: language, prompt: prompt).call
  end

  def initialize(audio:, language: nil, prompt: nil)
    @audio    = audio
    @language = language.to_s.strip.presence
    @prompt   = prompt.to_s.strip.presence
  end

  def call
    return err("missing_api_key", "Server is not configured for voice transcription.") if api_key.blank?
    return err("missing_audio", "No audio uploaded.") if @audio.nil?
    return err("audio_too_large", "Audio file exceeds 25MB.") if @audio.respond_to?(:size) && @audio.size.to_i > MAX_BYTES

    audio_bytes, filename, content_type = extract_blob(@audio)
    return err("missing_audio", "Empty audio payload.") if audio_bytes.blank?

    boundary = "WhisperBoundary-#{SecureRandom.hex(8)}"
    body = build_multipart(boundary, audio_bytes, filename, content_type)
    uri  = URI(API_URL)
    req  = Net::HTTP::Post.new(uri)
    req["authorization"] = "Bearer #{api_key}"
    req["content-type"]  = "multipart/form-data; boundary=#{boundary}"
    req.body = body

    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 60) { |h| h.request(req) }

    if resp.code.to_i != 200
      Rails.logger.warn("[Whisper] HTTP #{resp.code}: #{resp.body.to_s[0, 300]}")
      return err("api_error", "Transcription service returned #{resp.code}")
    end

    data = JSON.parse(resp.body)
    text = data["text"].to_s.strip
    duration = data["duration"].to_f
    cost = (duration / 60.0 * PRICE_PER_MINUTE).round(4)

    Rails.logger.info("[Whisper] ok duration=#{duration.round(1)}s bytes=#{audio_bytes.bytesize} cost≈$#{cost}")

    Result.new(ok?: true, text: text, duration_seconds: duration, cost_usd: cost)
  rescue => e
    Rails.logger.warn("[Whisper] exception: #{e.class} #{e.message}")
    err("exception", e.message)
  end

  private

  def api_key
    ENV["OPENAI_API_KEY"].to_s.strip
  end

  def err(code, message)
    Result.new(ok?: false, error: code, text: "", duration_seconds: 0.0, cost_usd: 0.0).tap do |r|
      r.instance_variable_set(:@message, message)
      r.define_singleton_method(:message) { message }
    end
  end

  def extract_blob(uploaded)
    if uploaded.respond_to?(:read)
      bytes = uploaded.read
      name  = uploaded.respond_to?(:original_filename) ? uploaded.original_filename : "audio.webm"
      type  = uploaded.respond_to?(:content_type) ? uploaded.content_type : "audio/webm"
      [ bytes, name, type ]
    else
      [ uploaded.to_s, "audio.webm", "audio/webm" ]
    end
  end

  def build_multipart(boundary, bytes, filename, content_type)
    crlf = "\r\n"
    parts = []

    parts << "--#{boundary}#{crlf}" \
             "Content-Disposition: form-data; name=\"model\"#{crlf}#{crlf}" \
             "#{MODEL}#{crlf}"

    if @language.present?
      parts << "--#{boundary}#{crlf}" \
               "Content-Disposition: form-data; name=\"language\"#{crlf}#{crlf}" \
               "#{@language}#{crlf}"
    end

    if @prompt.present?
      parts << "--#{boundary}#{crlf}" \
               "Content-Disposition: form-data; name=\"prompt\"#{crlf}#{crlf}" \
               "#{@prompt}#{crlf}"
    end

    parts << "--#{boundary}#{crlf}" \
             "Content-Disposition: form-data; name=\"response_format\"#{crlf}#{crlf}" \
             "verbose_json#{crlf}"

    parts << "--#{boundary}#{crlf}" \
             "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"#{crlf}" \
             "Content-Type: #{content_type}#{crlf}#{crlf}"

    head = parts.join.dup.force_encoding(Encoding::ASCII_8BIT)
    tail = "#{crlf}--#{boundary}--#{crlf}".dup.force_encoding(Encoding::ASCII_8BIT)

    head + bytes.dup.force_encoding(Encoding::ASCII_8BIT) + tail
  end
end
