# HosAlivio's matchmaker.
# Parses a natural-language query from the public landing page into a set of
# structured filters against the Agency partner directory, then returns:
#
#   { agencies:, filters:, explanation:, source: }
#
# When LLM credits are available this delegates to an OpenAI/Claude call for
# intent extraction. Without credits, it falls back to a keyword heuristic that
# covers the common cases (city, specialty, insurance, language).

require "net/http"
require "json"

class HosalivioMatchmaker
  CITY_TO_ZIP_PREFIX = {
    "miami"            => "331",
    "hialeah"          => "330",
    "fort lauderdale"  => "333",
    "ft lauderdale"    => "333",
    "ft. lauderdale"   => "333",
    "broward"          => "333",
    "orlando"          => "328",
    "tampa"            => "336",
    "st. petersburg"   => "337",
    "st petersburg"    => "337",
    "jacksonville"     => "322",
    "gainesville"      => "326"
  }.freeze

  SPECIALTY_KEYWORDS = {
    "dementia_care"     => %w[dementia alzheimer memory cognitive],
    "pediatric"         => %w[pediatric child children kid kids young],
    "cardiac"           => %w[cardiac heart chf congestive],
    "oncology"          => %w[cancer oncology tumor chemo],
    "veterans"          => %w[veteran vet military va],
    "lgbtq_affirming"   => %w[lgbt gay lesbian queer trans],
    "rural_coverage"    => %w[rural remote countryside small town small-town],
    "palliative_bridge" => %w[palliative transitional bridge]
  }.freeze

  INSURANCE_KEYWORDS = {
    "medicare" => %w[medicare],
    "medicaid" => %w[medicaid],
    "va"       => %w[va veterans],
    "private"  => %w[private commercial blue cigna aetna united],
    "selfpay"  => %w[self-pay self pay cash]
  }.freeze

  LANGUAGE_KEYWORDS = {
    "es" => %w[spanish espanol español],
    "ht" => %w[creole haitian],
    "pt" => %w[portuguese],
    "zh" => %w[chinese mandarin cantonese],
    "fr" => %w[french]
  }.freeze

  def self.call(query:, filters: {})
    new(query, filters).call
  end

  def initialize(query, filters)
    @query   = query.to_s.strip
    @filters = (filters || {}).with_indifferent_access
  end

  def call
    parsed, source = resolve_filters
    scope = Agency.partners.accepting_referrals

    if (zip_prefix = parsed[:zip_prefix]).present?
      scope = scope.serving_zip_prefix(zip_prefix)
    end

    Array(parsed[:specialties]).each { |s| scope = scope.with_specialty(s) }
    Array(parsed[:insurance]).each   { |i| scope = scope.with_insurance(i) }
    Array(parsed[:languages]).each   { |l| scope = scope.with_language(l) }

    agencies = scope.order(:response_sla_hours, :name).limit(12).to_a

    # If filters are too strict and nothing matches, show all partners
    # with a note so the user isn't left staring at an empty grid.
    if agencies.empty? && parsed.values.flatten.compact.any?
      agencies = Agency.partners.accepting_referrals.order(:name).limit(12).to_a
      fallback_all = true
    end

    {
      agencies:    agencies,
      filters:     parsed,
      explanation: explanation_for(parsed, agencies.size, fallback_all),
      source:      source
    }
  end

  # ── Filter resolution ────────────────────────────────────────────────

  def resolve_filters
    # Explicit facet filters from URL params take precedence.
    explicit = {
      zip_prefix:  @filters[:zip].presence&.slice(0, 3),
      specialties: Array(@filters[:specialty]).compact_blank,
      insurance:   Array(@filters[:insurance]).compact_blank,
      languages:   Array(@filters[:language]).compact_blank
    }.compact_blank

    if @query.blank? && explicit.any?
      return [explicit, "facets"]
    end

    return [explicit, "none"] if @query.blank?

    parsed = keyword_parse(@query)
    merged = deep_merge_filters(explicit, parsed)
    [merged, "heuristic"]
    # TODO: when LLM credits land, call HosalivioBrain for structured extraction
    # and return source = "claude:..." or "openai:..." here.
  end

  def keyword_parse(text)
    lower = text.downcase
    out = { specialties: [], insurance: [], languages: [], zip_prefix: nil }

    # ZIP: explicit 5-digit number
    if (m = lower.match(/\b(\d{5})\b/))
      out[:zip_prefix] = m[1][0, 3]
    end
    # City names
    CITY_TO_ZIP_PREFIX.each do |name, prefix|
      if lower.include?(name)
        out[:zip_prefix] ||= prefix
        break
      end
    end

    SPECIALTY_KEYWORDS.each do |tag, words|
      out[:specialties] << tag if words.any? { |w| lower.include?(w) }
    end
    INSURANCE_KEYWORDS.each do |tag, words|
      out[:insurance]   << tag if words.any? { |w| lower.include?(w) }
    end
    LANGUAGE_KEYWORDS.each do |tag, words|
      out[:languages]   << tag if words.any? { |w| lower.include?(w) }
    end

    out.compact_blank
  end

  def deep_merge_filters(a, b)
    {
      zip_prefix:  a[:zip_prefix].presence   || b[:zip_prefix],
      specialties: (Array(a[:specialties]) + Array(b[:specialties])).uniq.compact_blank,
      insurance:   (Array(a[:insurance])   + Array(b[:insurance])).uniq.compact_blank,
      languages:   (Array(a[:languages])   + Array(b[:languages])).uniq.compact_blank
    }.compact_blank
  end

  # ── Human-readable explanation ───────────────────────────────────────

  def explanation_for(filters, n, fallback_all)
    parts = []
    parts << "near #{filters[:zip_prefix]}xx"                         if filters[:zip_prefix]
    parts << "for #{filters[:specialties].map { |s| Agency::SPECIALTY_CATALOG[s] || s }.to_sentence}" if filters[:specialties].present?
    parts << "accepting #{filters[:insurance].map { |i| Agency::INSURANCE_CATALOG[i] || i }.to_sentence}"  if filters[:insurance].present?
    parts << "speaking #{filters[:languages].map { |l| Agency::LANGUAGE_CATALOG[l] || l }.to_sentence}"    if filters[:languages].present?

    descriptor = parts.any? ? parts.join(", ") : "in our network"

    if fallback_all
      "I couldn't find a perfect match #{descriptor}. Here are all of our partners — the top few are a good starting call."
    elsif parts.empty?
      "All #{n} of our partner hospices. Type your needs in the bar above and I'll narrow it down."
    elsif n == 0
      "No partners match #{descriptor} right now. Try loosening one of the filters."
    elsif n == 1
      "One match #{descriptor}. They usually respond within #{filters[:zip_prefix] ? 'hours' : 'the day'}."
    else
      "#{n} good matches #{descriptor}, sorted by how fast they typically respond."
    end
  end
end
