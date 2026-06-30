module Cms
  # Maps a primary ICD-10 to the Medicare hospice LCD ("Determining Terminal
  # Status") it falls under, and a coverage signal.
  #
  # The ICD-10 → category match is a deterministic heuristic; the category is
  # then resolved to a REAL, current CMS hospice LCD (id + cms.gov url) via
  # Cms::CoverageApi.cached_hospice_lcds (live-refreshed, with a verified baked-in
  # fallback). So the citation is authoritative; whether a specific code is
  # *covered* under that LCD still depends on documented terminal decline, which
  # is why this informs — it doesn't block — certification.
  class HospiceCoverage
    # Ordered: first match wins. [regex over the dotless UPPER code, a title
    # pattern matching the governing hospice LCD].
    LCD_RULES = [
      [ /\AI50/,                  /cardiopulmonary/i ],
      [ /\AI(?:[0-4]\d|5[0-2])/,  /cardiopulmonary/i ],   # I00–I52 heart
      [ /\AJ4[0-7]/,              /cardiopulmonary/i ],   # COPD
      [ /\AJ8[0-4]/,              /cardiopulmonary/i ],   # ILD
      [ /\AI6/,                   /neurolog/i ],          # stroke
      [ /\AG9[123]/,              /neurolog/i ],          # coma
      [ /\AG20/,                  /neurolog/i ],          # Parkinson's
      [ /\AG12/,                  /neurolog/i ],          # ALS
      [ /\AG35/,                  /neurolog/i ],          # MS
      [ /\A(?:G30|F0[0-3])/,      /alzheimer/i ],         # dementia
      [ /\AN1[789]/,              /renal/i ],             # N17–N19
      [ /\AK7[0-7]/,              /liver/i ],
      [ /\A(?:R6[24]|R53)/,       /failure to thrive/i ], # debility/FTT
      [ /\A(?:C|D0|B20)/,         /determining terminal status/i ] # cancer, HIV → general
    ].freeze

    Result = Struct.new(:status, :lcd_id, :lcd_title, :lcd_url, :summary, keyword_init: true)

    def self.call(code)
      new(code).call
    end

    def initialize(code)
      @code = Coding::Icd10.normalize(code)
    end

    def call
      return needs_review("No diagnosis code on file.") if @code.empty?
      title_re = LCD_RULES.find { |re, _| @code.match?(re) }&.last
      unless title_re
        return needs_review("#{@code} doesn't match a hospice terminal-status LCD category. Verify coverage and consider a more specific terminal diagnosis.")
      end

      lcd  = Cms::CoverageApi.cached_hospice_lcds.find { |l| l["title"].to_s.match?(title_re) }
      cite = lcd ? "#{lcd['id']} (#{lcd['title']})" : "for this category"
      Result.new(
        status:    :likely_covered,
        lcd_id:    lcd&.dig("id"),
        lcd_title: lcd&.dig("title"),
        lcd_url:   lcd&.dig("url"),
        summary:   "#{@code} maps to the Medicare hospice LCD #{cite}. Eligibility still requires documented terminal decline — confirm against the LCD."
      )
    end

    private

    def needs_review(summary)
      Result.new(status: :needs_review, summary: summary)
    end
  end
end
