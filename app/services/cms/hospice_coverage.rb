module Cms
  # Maps a primary ICD-10 to the Medicare hospice LCD ("Determining Terminal
  # Status") disease category it falls under, and a coverage signal.
  #
  # Deterministic and OFFLINE: it encodes the standard hospice-LCD disease
  # categories by ICD-10 range. It does NOT call api.coverage.cms.gov, whose LCD
  # data endpoints currently require a CMS auth token (+ AMA CPT license). When
  # that token is configured, a live LCD lookup can replace `match_lcd` without
  # changing callers — same Result shape.
  class HospiceCoverage
    # Ordered: first match wins, so specific patterns precede broad ones.
    # [regex over the dotless UPPER code, hospice LCD label].
    LCD_MAP = [
      [ /\AI50/,                 "Heart Disease — CHF" ],
      [ /\AI(?:[0-4]\d|5[0-2])/, "Heart Disease" ],                 # I00–I52
      [ /\AI6/,                  "Stroke / Cerebrovascular" ],      # I60–I69
      [ /\AC/,                   "Neoplasms (Cancer)" ],            # C00–C99
      [ /\AD0/,                  "Neoplasms (in situ)" ],           # D00–D09
      [ /\AG30/,                 "Alzheimer's / Dementia" ],
      [ /\AF0[0-3]/,             "Dementia" ],
      [ /\AG20/,                 "Parkinson's Disease" ],
      [ /\AG12/,                 "ALS / Motor Neuron Disease" ],
      [ /\AG35/,                 "Multiple Sclerosis" ],
      [ /\AG9[123]/,             "Coma / Persistent Vegetative State" ],
      [ /\AJ4[0-7]/,             "Pulmonary — COPD" ],
      [ /\AJ8[0-4]/,             "Pulmonary — Interstitial Lung Disease" ],
      [ /\AN1[789]/,             "Renal Disease" ],                 # N17–N19
      [ /\AK7[0-7]/,             "Liver Disease" ],
      [ /\AB20/,                 "HIV / AIDS" ],
      [ /\A(?:R6[24]|R53)/,      "Adult Failure to Thrive / Debility" ]
    ].freeze

    Result = Struct.new(:status, :lcd, :summary, keyword_init: true)

    def self.call(code)
      new(code).call
    end

    def initialize(code)
      @code = Coding::Icd10.normalize(code)
    end

    def call
      return needs_review("No diagnosis code on file.") if @code.empty?
      lcd = match_lcd(@code)
      return needs_review("#{@code} doesn't match a standard hospice terminal-status LCD category. Automated check — verify against the CMS Coverage Database and consider a more specific terminal diagnosis.") unless lcd

      Result.new(
        status:  :likely_covered,
        lcd:     lcd,
        summary: "#{@code} matches the Medicare hospice LCD category for #{lcd} (Determining Terminal Status). Automated heuristic — confirm against the CMS Coverage Database; eligibility still requires documented terminal decline."
      )
    end

    private

    def match_lcd(code)
      LCD_MAP.each { |re, label| return label if code.match?(re) }
      nil
    end

    def needs_review(summary)
      Result.new(status: :needs_review, lcd: nil, summary: summary)
    end
  end
end
