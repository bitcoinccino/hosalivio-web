module Coding
  # Thin lookup/validation over the local ICD-10-CM index (Icd10Code, ~71k rows).
  # The full code set is already seeded, so diagnosis validation needs no external
  # API — we just confirm the code exists and pull its authoritative description.
  class Icd10
    FORMAT = /\A[A-Z]\d{2}(?:\.?\w{1,4})?\z/

    def self.normalize(code)
      code.to_s.strip.upcase.delete(" ")
    end

    # The authoritative ICD-10-CM record, matched with or without the decimal
    # ("A09", "C50.9", "C509" all resolve). nil when the code doesn't exist.
    def self.lookup(code)
      norm = normalize(code)
      return nil if norm.empty?
      Icd10Code.where("REPLACE(UPPER(code), '.', '') = ?", norm.delete(".")).first
    end

    def self.valid?(code)
      lookup(code).present?
    end

    def self.describe(code)
      lookup(code)&.description
    end
  end
end
