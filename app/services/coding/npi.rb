require "net/http"

module Coding
  # NPPES NPI Registry connector — CMS's free, unauthenticated provider
  # directory (npiregistry.cms.hhs.gov). Resolves a referring clinician or
  # organization to a validated National Provider Identifier.
  #
  # Trust rule: only a SINGLE unambiguous match is accepted. Zero matches, more
  # than one match, a timeout, or any error all return nil — the caller keeps
  # the plain provider-name string and the intake pipeline never stalls.
  #
  # Dormant-safe, matching the app's external-connector convention (cf. Dpc /
  # Coding::RxNorm): OFF unless NPI_LIVE_LOOKUP is set, always OFF in test (no
  # network in CI), 3s timeout, results cached.
  class Npi
    SYSTEM       = "http://hl7.org/fhir/sid/us-npi".freeze
    BASE         = "https://npiregistry.cms.hhs.gov/api/".freeze
    API_VERSION  = "2.1".freeze
    HTTP_TIMEOUT = 3 # seconds

    Result = Struct.new(:npi, :name, :credential, :taxonomy, keyword_init: true)

    class << self
      # Individual (first/last) or organization (organization_name), optionally
      # geo-filtered by state / postal_code. Returns a Result or nil.
      def lookup(first_name: nil, last_name: nil, organization_name: nil, state: nil, postal_code: nil)
        return nil unless live_enabled?
        params = build_params(first_name: first_name, last_name: last_name,
                              organization_name: organization_name, state: state, postal_code: postal_code)
        return nil if params.empty?

        data = Rails.cache.fetch("npi:#{params.sort.to_h.to_json}", expires_in: 30.days) { fetch(params) }
        data && Result.new(npi: data["npi"], name: data["name"], credential: data["credential"], taxonomy: data["taxonomy"])
      rescue => e
        Rails.logger.warn("[Coding::Npi] lookup failed: #{e.class}: #{e.message}")
        nil
      end

      def live_enabled?
        return false if Rails.env.test?
        flag = ENV["NPI_LIVE_LOOKUP"].to_s.strip
        flag.present? && flag != "0"
      end

      # limit: 2 so result_count distinguishes "exactly one" from "many".
      def build_params(first_name:, last_name:, organization_name:, state:, postal_code:)
        params = { version: API_VERSION, limit: 2 }
        if organization_name.present?
          params[:organization_name] = organization_name
          params[:enumeration_type]  = "NPI-2"
        elsif last_name.present?
          params[:last_name]        = last_name
          params[:first_name]       = first_name if first_name.present?
          params[:enumeration_type] = "NPI-1"
        else
          return {}
        end
        params[:state]       = state       if state.present?
        params[:postal_code] = postal_code if postal_code.present?
        params
      end

      def fetch(params)
        parse_single(nppes_get(params))
      end

      # ── pure parser (network-free, unit-testable) ───────────────────
      # Trust only an unambiguous single match.
      def parse_single(json)
        return nil unless json && json["result_count"] == 1
        result = Array(json["results"]).first
        return nil if result.nil? || result["number"].blank?
        {
          "npi"        => result["number"].to_s,
          "name"       => provider_name(result),
          "credential" => result.dig("basic", "credential").presence,
          "taxonomy"   => primary_taxonomy(result)
        }
      end

      def provider_name(result)
        basic = result["basic"] || {}
        basic["organization_name"].presence ||
          [ basic["first_name"], basic["last_name"] ].map { |s| s.to_s.strip.presence }.compact.join(" ").presence
      end

      def primary_taxonomy(result)
        taxes = Array(result["taxonomies"])
        (taxes.find { |t| t["primary"] } || taxes.first)&.dig("desc").presence
      end

      def nppes_get(params)
        uri = URI(BASE)
        uri.query = URI.encode_www_form(params)
        res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                              open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT) do |http|
          http.get(uri.request_uri, "Accept" => "application/json")
        end
        res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
      end
    end
  end
end
