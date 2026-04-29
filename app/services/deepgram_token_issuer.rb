# Mints short-TTL Deepgram API keys via the Management API so the
# browser can open a WebSocket directly to Deepgram without exposing
# the long-lived account key. Each issued key is scoped to
# `usage:write` (just streaming) and expires within an hour. Deepgram
# bills against our project for any usage made with the temp key.
#
# Env:
#   DEEPGRAM_API_KEY     long-lived management key (kept server-side)
#   DEEPGRAM_PROJECT_ID  the project to mint keys under
#
# Returns: { key:, expiration_date:, source: "deepgram" } or nil on
# failure (transient API error / missing config). Callers fall back
# to Web Speech when nil is returned.

require "net/http"
require "json"

class DeepgramTokenIssuer
  MANAGEMENT_BASE = "https://api.deepgram.com/v1".freeze
  DEFAULT_TTL_SECONDS = 3_600

  def self.issue(comment:, ttl: DEFAULT_TTL_SECONDS, scopes: %w[usage:write])
    api_key    = ENV["DEEPGRAM_API_KEY"].to_s
    project_id = ENV["DEEPGRAM_PROJECT_ID"].to_s
    return nil if api_key.blank? || project_id.blank?

    uri = URI("#{MANAGEMENT_BASE}/projects/#{project_id}/keys")
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Token #{api_key}"
    req["Content-Type"]  = "application/json"
    req.body = {
      comment:                  comment.to_s[0, 100],
      scopes:                   scopes,
      time_to_live_in_seconds:  ttl
    }.to_json

    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 10) { |h| h.request(req) }
    if resp.code.to_i == 201
      data = JSON.parse(resp.body)
      {
        "key"             => data["key"],
        "expiration_date" => data["expiration_date"],
        "source"          => "deepgram"
      }
    else
      Rails.logger.warn("[DeepgramTokenIssuer] #{resp.code}: #{resp.body.to_s[0, 200]}")
      nil
    end
  rescue => e
    Rails.logger.warn("[DeepgramTokenIssuer] #{e.class}: #{e.message}")
    nil
  end
end
