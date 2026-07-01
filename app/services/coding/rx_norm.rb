module Coding
  # Minimal RxNorm ingredient lookup for the baseline comfort-kit formulary
  # (see Medications::InitializeComfortKitService::BASELINE_KIT_ITEMS). The app
  # has no full RxNorm index, so rather than fabricate codes we map only the
  # known comfort-kit ingredients to their stable ingredient-level RxNorm CUIs
  # (TTY=IN). Anything we don't recognize returns nil and stays text-only in FHIR.
  class RxNorm
    SYSTEM = "http://www.nlm.nih.gov/research/umls/rxnorm".freeze

    # Keyed by generic + brand keywords that appear in an order's drug_name.
    INGREDIENTS = [
      { rxcui: "161",  name: "Acetaminophen",    match: %w[acetaminophen tylenol] },
      { rxcui: "6470", name: "Lorazepam",        match: %w[lorazepam ativan] },
      { rxcui: "1223", name: "Atropine",         match: %w[atropine] },
      { rxcui: "8704", name: "Prochlorperazine", match: %w[prochlorperazine compazine] },
      { rxcui: "1594", name: "Bisacodyl",        match: %w[bisacodyl dulcolax] },
      { rxcui: "7052", name: "Morphine",         match: %w[morphine roxanol] }
    ].freeze

    Result = Struct.new(:rxcui, :name, keyword_init: true)

    # Best-effort ingredient match on a free-text drug name. Returns a Result
    # (rxcui + canonical ingredient name) or nil.
    def self.lookup(drug_name)
      text = drug_name.to_s.downcase
      return nil if text.strip.empty?

      hit = INGREDIENTS.find { |ing| ing[:match].any? { |kw| text.include?(kw) } }
      hit && Result.new(rxcui: hit[:rxcui], name: hit[:name])
    end
  end
end
