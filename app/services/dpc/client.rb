require "net/http"
require "json"
require "jwt"

module Dpc
  # Thin DPC API client: SMART Backend Services auth → bulk $export of
  # ExplanationOfBenefit → parsed diagnosis history.
  #
  # NETWORK SHAPE follows the DPC docs (https://dpc.cms.gov/docsV1): a JWT client
  # assertion signed with our registered private key is exchanged for a bearer
  # token; an async $export returns a status URL we poll, then fetch NDJSON
  # output. It is NOT yet exercised against the live sandbox — verify on
  # activation. Every path returns [] (never raises) when unconfigured or on
  # error, so callers degrade silently.
  class Client
    AUTH_PATH   = "/Token"
    EXPORT_TYPE = "ExplanationOfBenefit"
    SIGNING_ALG = "RS384" # SMART Backend Services
    MAX_POLLS   = 10
    POLL_WAIT   = 2 # seconds

    # Returns Dpc::EobToDiagnoses::Diagnosis rows for a DPC patient id, or [].
    def diagnoses_for(patient_dpc_id)
      return [] unless Dpc.configured? && patient_dpc_id.present?
      token  = access_token or return []
      ndjson = export_eob_ndjson(patient_dpc_id, token)
      EobToDiagnoses.call(ndjson)
    rescue => e
      Rails.logger.warn("[Dpc::Client] #{e.class}: #{e.message}")
      []
    end

    private

    # SMART BSA: sign a short-lived JWT assertion with our private key and trade
    # it for an access_token.
    def access_token
      assertion = JWT.encode(
        { iss: ENV.fetch("DPC_CLIENT_TOKEN"), sub: ENV.fetch("DPC_CLIENT_TOKEN"),
          aud: "#{Dpc.base_url}#{AUTH_PATH}", exp: 5.minutes.from_now.to_i, jti: SecureRandom.uuid },
        OpenSSL::PKey::RSA.new(ENV.fetch("DPC_PRIVATE_KEY")), SIGNING_ALG
      )
      resp = post_form("#{Dpc.base_url}#{AUTH_PATH}",
        grant_type:            "client_credentials",
        scope:                 "system/*.read",
        client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        client_assertion:      assertion)
      resp && JSON.parse(resp)["access_token"]
    end

    # Kick off an async $export scoped to the patient, poll the status URL, then
    # fetch and concatenate the NDJSON output.
    def export_eob_ndjson(patient_dpc_id, token)
      status_url = trigger_export(patient_dpc_id, token) or return ""
      output     = poll_until_done(status_url, token)
      output.map { |url| http_get(url, token, accept: "application/fhir+ndjson") }.compact.join("\n")
    end

    def trigger_export(patient_dpc_id, token)
      uri = URI("#{Dpc.base_url}/Patient/#{patient_dpc_id}/$export?_type=#{EXPORT_TYPE}")
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{token}"
      req["Accept"]        = "application/fhir+json"
      req["Prefer"]        = "respond-async"
      resp = perform(uri, req)
      resp&.code == "202" ? resp["Content-Location"] : nil
    end

    def poll_until_done(status_url, token)
      MAX_POLLS.times do
        body = http_get_response(status_url, token, accept: "application/json")
        return Array(JSON.parse(body.body)["output"]).filter_map { |o| o["url"] } if body&.code == "200"
        sleep POLL_WAIT
      end
      []
    end

    # ── HTTP helpers ──────────────────────────────────────────────────
    def post_form(url, **form)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req.set_form_data(form)
      resp = perform(uri, req)
      resp&.code == "200" ? resp.body : nil
    end

    def http_get(url, token, accept:)
      http_get_response(url, token, accept: accept)&.then { |r| r.code == "200" ? r.body : nil }
    end

    def http_get_response(url, token, accept:)
      uri = URI(url)
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{token}"
      req["Accept"]        = accept
      perform(uri, req)
    end

    def perform(uri, req)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                      open_timeout: 10, read_timeout: 30) { |h| h.request(req) }
    end
  end
end
