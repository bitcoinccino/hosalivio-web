require "net/http"
require "uri"

# Outbound transmission of a certified pre-admit evaluation to an external
# EMR (the VITAS portal — standard HL7 FHIR + custom REST endpoints).
#
# Decoupled from the request loop on purpose: external EMR networks are slow
# and rate-limited, so we never call them inline. This job compiles the
# compliant payload, ships it through the gateway with a bearer token, and
# tracks the lifecycle on a per-(eval, target) EmrSyncLog with
# exponential-backoff retries.
#
# DORMANT until both env vars are set — VITAS_GATEWAY_URL and
# VITAS_API_BEARER_TOKEN. Enqueue is a no-op otherwise (see
# PreAdmitEval#enqueue_emr_sync), so wiring it into the certify flow today is
# safe; it "wakes up" the moment credentials land.
class VitasEmrSyncJob < ApplicationJob
  queue_as :default

  # Network blips back off and retry; a non-2xx / unacknowledged response
  # raises SyncFailed, which rides the same curve.
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  class SyncFailed < StandardError; end

  TARGET = "VITAS_PORTAL"

  def self.configured?
    ENV["VITAS_GATEWAY_URL"].to_s.present? &&
      ENV["VITAS_API_BEARER_TOKEN"].to_s.present?
  end

  def perform(eval_id)
    return unless self.class.configured?

    eval_rec = PreAdmitEval.unscoped.find_by(id: eval_id)
    return unless eval_rec

    ActsAsTenant.with_tenant(eval_rec.agency) do
      log = EmrSyncLog.find_or_create_by!(
        pre_admit_eval: eval_rec,
        agency:         eval_rec.agency,
        target_system:  TARGET
      )
      return if log.status == "synchronized"

      log.update!(status: "processing")
      eval_rec.update!(sync_status: :processing)

      payload = eval_rec.compile_vitas_payload
      log.update!(payload_sent: payload)

      response = dispatch(payload, eval_rec)
      parsed   = parse_body(response)
      log.update!(response_received: parsed)

      if response.is_a?(Net::HTTPSuccess) && parsed["encounter_status"] == "acknowledged"
        log.update!(
          status:                "synchronized",
          external_encounter_id: parsed["vitas_encounter_id"],
          synchronized_at:       Time.current
        )
        eval_rec.update!(sync_status: :synced)
      else
        log.update!(status: "failed", retry_count: log.retry_count + 1)
        eval_rec.update!(sync_status: :failed)
        raise SyncFailed,
              "VITAS EMR sync failed: HTTP #{response.code} — #{response.body.to_s.truncate(300)}"
      end
    end
  end

  private

  def dispatch(payload, eval_rec)
    uri = URI(ENV.fetch("VITAS_GATEWAY_URL"))
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"]         = "application/json"
    req["Authorization"]        = "Bearer #{ENV.fetch('VITAS_API_BEARER_TOKEN')}"
    req["X-Tenant-Provider-ID"] = eval_rec.agency_id.to_s
    req.body = payload.to_json

    Net::HTTP.start(uri.host, uri.port,
                    use_ssl: uri.scheme == "https",
                    open_timeout: 10, read_timeout: 30) do |http|
      http.request(req)
    end
  end

  def parse_body(response)
    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    { "raw" => response.body.to_s.truncate(1000) }
  end
end
