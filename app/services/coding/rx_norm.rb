require "net/http"

module Coding
  # RxNorm ingredient lookup for FHIR MedicationRequest coding.
  #
  # Two layers:
  #   1. A static map of the baseline comfort-kit formulary — fast, offline,
  #      deterministic, every RXCUI verified against NLM RxNav.
  #   2. A live fallback against the NLM RxNav REST API for any drug not in the
  #      kit, so arbitrary medications still get a real code instead of staying
  #      text-only.
  #
  # The live layer is dormant-safe, matching the app's external-connector
  # convention (cf. Dpc): OFF unless RXNAV_LIVE_LOOKUP is set, always OFF in
  # test (no network in CI), short timeout, and any failure returns nil so the
  # drug simply falls back to text-only. Results are cached (RxNorm ingredient
  # CUIs are stable).
  class RxNorm
    SYSTEM       = "http://www.nlm.nih.gov/research/umls/rxnorm".freeze
    RXNAV_BASE   = "https://rxnav.nlm.nih.gov/REST".freeze
    HTTP_TIMEOUT = 3 # seconds — RxNav is fast; never block a bundle build on it.

    # Ingredient-level (TTY=IN) CUIs for the baseline comfort kit, keyed by
    # generic + brand keywords in drug_name. All verified against NLM RxNav
    # (e.g. bisacodyl is 1596, not 1594).
    INGREDIENTS = [
      { rxcui: "161",  name: "Acetaminophen",    match: %w[acetaminophen tylenol] },
      { rxcui: "6470", name: "Lorazepam",        match: %w[lorazepam ativan] },
      { rxcui: "1223", name: "Atropine",         match: %w[atropine] },
      { rxcui: "8704", name: "Prochlorperazine", match: %w[prochlorperazine compazine] },
      { rxcui: "1596", name: "Bisacodyl",        match: %w[bisacodyl dulcolax] },
      { rxcui: "7052", name: "Morphine",         match: %w[morphine roxanol] }
    ].freeze

    Result = Struct.new(:rxcui, :name, keyword_init: true)

    class << self
      # Static kit match first; live RxNav fallback for anything else.
      def lookup(drug_name)
        text = drug_name.to_s.strip
        return nil if text.empty?
        static_lookup(text) || live_lookup(text)
      end

      def static_lookup(drug_name)
        text = drug_name.to_s.downcase
        return nil if text.empty?
        hit = INGREDIENTS.find { |ing| ing[:match].any? { |kw| text.include?(kw) } }
        hit && Result.new(rxcui: hit[:rxcui], name: hit[:name])
      end

      # Live RxNav ingredient resolution. Dormant-safe: returns nil unless
      # enabled, and swallows any network/parse error.
      def live_lookup(drug_name)
        return nil unless live_enabled?

        data = Rails.cache.fetch("rxnorm:ingredient:#{drug_name.downcase}", expires_in: 30.days) do
          fetch_ingredient(drug_name)
        end
        data && Result.new(rxcui: data["rxcui"], name: data["name"])
      rescue => e
        Rails.logger.warn("[Coding::RxNorm] live lookup failed for #{drug_name.inspect}: #{e.class}: #{e.message}")
        nil
      end

      def live_enabled?
        return false if Rails.env.test?
        flag = ENV["RXNAV_LIVE_LOOKUP"].to_s.strip
        flag.present? && flag != "0"
      end

      # Best-approximate match → its ingredient (TTY=IN). Returns
      # {"rxcui"=>, "name"=>} or nil.
      def fetch_ingredient(drug_name)
        rxcui = parse_approx_rxcui(rxnav_get("/approximateTerm.json", term: drug_name, maxEntries: 1))
        return nil if rxcui.blank?
        parse_ingredient(rxnav_get("/rxcui/#{rxcui}/related.json", tty: "IN"))
      end

      # ── pure parsers (network-free, unit-testable) ──────────────────
      def parse_approx_rxcui(json)
        json&.dig("approximateGroup", "candidate")&.first&.dig("rxcui")
      end

      def parse_ingredient(json)
        group = Array(json&.dig("relatedGroup", "conceptGroup")).find { |g| g["tty"] == "IN" }
        prop  = group && Array(group["conceptProperties"]).first
        prop && { "rxcui" => prop["rxcui"], "name" => prop["name"] }
      end

      # HTTP boundary, isolated from parsing.
      def rxnav_get(path, params)
        uri = URI("#{RXNAV_BASE}#{path}")
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
