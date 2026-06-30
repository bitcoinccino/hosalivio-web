require "net/http"
require "json"

module Cms
  # Live client for the CMS Medicare Coverage API (api.coverage.cms.gov). No
  # registration key needed: the LCD endpoints are gated by a short-lived
  # *license-agreement* token that we fetch ourselves (accepting the AMA/ADA/AHA
  # terms), then pass as a bearer.
  #
  # Used only to refresh the hospice LCD list (CmsHospiceLcdRefreshJob). The
  # request path never calls out — Cms::HospiceCoverage reads the cached list,
  # which falls back to a baked-in, live-verified set so it always cites a real
  # LCD even offline.
  class CoverageApi
    BASE       = "https://api.coverage.cms.gov"
    CACHE_KEY  = "cms:hospice_lcds"
    CACHE_TTL  = 8.days

    # The real, current Medicare hospice LCDs (verified live from the Coverage
    # API). Baked in so coverage always references a genuine LCD; the refresh job
    # keeps the cached copy current (URLs/versions change).
    FALLBACK_LCDS = [
      { "id" => "L34538", "title" => "Hospice Determining Terminal Status",            "url" => "https://www.cms.gov/medicare-coverage-database/view/lcd.aspx?lcdid=34538" },
      { "id" => "L34548", "title" => "Hospice Cardiopulmonary Conditions",             "url" => "https://www.cms.gov/medicare-coverage-database/view/lcd.aspx?lcdid=34548" },
      { "id" => "L34559", "title" => "Hospice - Renal Care",                           "url" => "https://www.cms.gov/medicare-coverage-database/view/lcd.aspx?lcdid=34559" },
      { "id" => "L34547", "title" => "Hospice - Neurological Conditions",              "url" => "https://www.cms.gov/medicare-coverage-database/view/lcd.aspx?lcdid=34547" },
      { "id" => "L34544", "title" => "Hospice - Liver Disease",                        "url" => "https://www.cms.gov/medicare-coverage-database/view/lcd.aspx?lcdid=34544" },
      { "id" => "L34567", "title" => "Hospice Alzheimer's Disease & Related Disorders", "url" => "https://www.cms.gov/medicare-coverage-database/view/lcd.aspx?lcdid=34567" },
      { "id" => "L34558", "title" => "Hospice The Adult Failure To Thrive Syndrome",   "url" => "https://www.cms.gov/medicare-coverage-database/view/lcd.aspx?lcdid=34558" }
    ].freeze

    # Hospice LCDs for matching — cached if the refresh job has run, else the
    # baked-in set. Never empty, never does I/O.
    def self.cached_hospice_lcds
      cached = Rails.cache.read(CACHE_KEY)
      cached.is_a?(Array) && cached.any? ? cached : FALLBACK_LCDS
    end

    # Pull the live list and cache it. Returns the list (or the fallback on
    # failure). Called by the refresh job; safe to run on demand.
    def self.refresh_hospice_lcds!
      live = fetch_hospice_lcds
      Rails.cache.write(CACHE_KEY, live, expires_in: CACHE_TTL) if live.any?
      live.presence || FALLBACK_LCDS
    end

    # license token → final-LCD report → hospice rows. [] on any failure.
    def self.fetch_hospice_lcds
      token = license_token or return []
      body  = get("#{BASE}/v1/reports/local-coverage-final-lcds?pageSize=500", token: token) or return []
      rows  = JSON.parse(body)["data"]
      return [] unless rows.is_a?(Array)
      rows.select { |r| r["title"].to_s.match?(/hospice/i) }
          .map { |r| { "id" => r["document_display_id"].to_s, "title" => r["title"].to_s, "url" => r["url"].to_s } }
          .reject { |l| l["id"].empty? }
    rescue => e
      Rails.logger.warn("[Cms::CoverageApi] #{e.class}: #{e.message}")
      []
    end

    def self.license_token
      body = get("#{BASE}/v1/metadata/license-agreement") or return nil
      JSON.parse(body).dig("data", 0, "Token")
    rescue
      nil
    end

    def self.get(url, token: nil)
      uri = URI(url)
      req = Net::HTTP::Get.new(uri)
      req["accept"]        = "application/json"
      req["user-agent"]    = "HosAlivio/1.0 (hospice EMR)"
      req["authorization"] = "Bearer #{token}" if token
      resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 8, read_timeout: 20) { |h| h.request(req) }
      resp.code == "200" ? resp.body : nil
    end
  end
end
