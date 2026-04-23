# Regex-based first pass over a free-text visit narrative. Lifts common
# admission-assessment signals into the pre_admit_eval JSON so Pascal
# doesn't have to enter the same data twice.
#
# Deliberately conservative: if a field isn't explicitly mentioned, leave
# it empty. Follows Pascal's SOUL's never-infer rule.
#
# When Anthropic credits land, AgentBrain can replace this service behind
# the same interface — the controller contract is (narrative, existing_json)
# → merged_json. Swap the implementation, keep the UX.
class PreAdmitNarrativeExtractor
  Result = Struct.new(:json, :fields_updated, keyword_init: true)

  def self.call(narrative:, existing_json: nil)
    new(narrative: narrative, existing_json: existing_json).call
  end

  def initialize(narrative:, existing_json: nil)
    @text    = narrative.to_s
    @lower   = @text.downcase
    @base    = existing_json.is_a?(Hash) ? existing_json.deep_dup : {}
    @updated = []
  end

  def call
    eval_root = (@base["pre_admit_eval"] ||= {})
    eval_root["general"]             ||= {}
    eval_root["functional_decline"]  ||= {}
    eval_root["nutritional_decline"] ||= {}
    eval_root["cognitive_decline"]   ||= {}
    eval_root["other_symptoms"]      ||= {}
    eval_root["informed_consent"]    ||= {}
    eval_root["election_of_benefit"] ||= {}
    eval_root["financial_consent"]   ||= {}
    eval_root["medicare_lcd_criteria"] ||= { "criteria_met" => [], "supporting_documentation" => "" }

    # Functional: PPS
    if (m = @lower.match(/\bpps\s*(?:is|at|of|=|:)?\s*(\d{1,3})\s*%?/))
      pps = m[1].to_i
      if pps.between?(10, 100)
        eval_root["functional_decline"]["pps_score"] = "#{pps}%"
        touch("functional_decline.pps_score")
      end
    end

    # Mobility
    %w[bedbound chairbound ambulatory].each do |word|
      if @lower.include?(word)
        eval_root["functional_decline"]["mobility_status"] ||= word
        touch("functional_decline.mobility_status")
        break
      end
    end

    # ADL mentions — flip explicitly stated dependencies into broad strings
    adls = eval_root["functional_decline"]["adl_dependence"] ||= {}
    { "bathing" => /\bbathing\b/, "dressing" => /\bdressing\b/,
      "toileting" => /\btoileting\b/, "transferring" => /\btransfer/,
      "continence" => /\bincontinen/, "feeding" => /\bfeeding\b/ }.each do |key, rx|
      if @lower.match?(rx) && adls[key].to_s.empty?
        if @lower.match?(/\b(needs|requires|total|full)\s+(help|assistance|dependence)\b/) ||
           @lower.match?(/dependence in|dependent in/)
          adls[key] = "assistance"
          touch("functional_decline.adl_dependence.#{key}")
        end
      end
    end

    # Nutritional: weight loss pattern
    if (m = @text.match(/lost\s+(\d{1,3})\s*(lbs?|pounds?|kg)\s+in\s+(\d{1,3})\s*(days?|weeks?|months?)/i))
      eval_root["nutritional_decline"]["weight_loss"] = "#{m[1]} #{m[2]} in #{m[3]} #{m[4]}"
      touch("nutritional_decline.weight_loss")
    end
    if (m = @lower.match(/(\d{1,2})\s*%\s+(?:weight\s+loss|loss)\s+(?:in|over)\s+(\d{1,2})\s*(months?|mo)/))
      eval_root["nutritional_decline"]["percent_weight_loss_6mo"] = "#{m[1]}%" if m[2].start_with?("mo") || m[2].include?("month")
      touch("nutritional_decline.percent_weight_loss_6mo")
    end
    if (m = @lower.match(/albumin\s*(?:of|is|=|:)?\s*(\d+(?:\.\d+)?)/))
      eval_root["nutritional_decline"]["albumin_level"] = m[1]
      touch("nutritional_decline.albumin_level")
    end
    if @lower.match?(/\bdysphagia\b/)
      eval_root["nutritional_decline"]["dysphagia"] ||= "present"
      touch("nutritional_decline.dysphagia")
    end

    # Symptoms (dyspnea, pain, agitation, anxiety, wounds)
    if @lower.match?(/dyspnea\s+at\s+rest|dyspneic\s+at\s+rest|short(?:ness)?\s+of\s+breath\s+at\s+rest/)
      eval_root["other_symptoms"]["dyspnea"] = "at rest"
      touch("other_symptoms.dyspnea")
    end
    if (m = @lower.match(/pain\s*(?:score|level|of|at|:)?\s*(\d{1,2})(?:\s*\/\s*10)?/))
      eval_root["other_symptoms"]["pain"] = "#{m[1]}/10" if m[1].to_i.between?(0, 10)
      touch("other_symptoms.pain")
    end
    if @lower.include?("pressure ulcer") || @lower.match?(/stage\s+\d\b/) || @lower.include?("wound")
      eval_root["other_symptoms"]["wounds"] ||= "present"
      touch("other_symptoms.wounds")
    end

    # Consent + Election (the key bridging phrases)
    if @lower.match?(/agrees?\s+to\s+stop\s+(curative|aggressive|treatment)|stop(ping)?\s+(curative|aggressive)\s+treatment/)
      eval_root["informed_consent"]["curative_treatment_stop_explained"] = true
      eval_root["informed_consent"]["family_agrees_to_stop_curative"]    = true
      touch("informed_consent.family_agrees_to_stop_curative")
    end
    if @lower.match?(/signed\s+(the\s+)?(election|mhes|medicare\s+hospice\s+election)/)
      eval_root["election_of_benefit"]["mhes_signed"] = true
      eval_root["election_of_benefit"]["election_effective_date"] = Date.current.iso8601 if eval_root["election_of_benefit"]["election_effective_date"].to_s.empty?
      touch("election_of_benefit.mhes_signed")
    end
    if @lower.match?(/(answered\s+(all\s+)?(her\s+|his\s+|their\s+)?questions|had\s+the\s+opportunity\s+to\s+ask|family\s+had\s+questions)/)
      eval_root["informed_consent"]["questions_answered"] = true
      touch("informed_consent.questions_answered")
    end
    if @lower.match?(/services?\s+(were\s+)?explained|explained\s+(the\s+)?services/)
      eval_root["informed_consent"]["services_explained"] = true
      touch("informed_consent.services_explained")
    end
    if @lower.match?(/levels?\s+of\s+care|explained\s+(the\s+)?four\s+levels/)
      eval_root["informed_consent"]["levels_of_care_explained"] = true
      touch("informed_consent.levels_of_care_explained")
    end
    if @lower.match?(/(wants?\s+to\s+proceed|ready\s+to\s+(move|go)\s+forward|agrees?\s+to\s+(proceed|admission))/)
      eval_root["informed_consent"]["family_wants_to_proceed"] = true
      touch("informed_consent.family_wants_to_proceed")
    end

    # Financial consent
    if @lower.match?(/assignment\s+of\s+benefits|aob\s+signed|signed\s+(the\s+)?aob/)
      eval_root["financial_consent"]["assignment_of_benefits_signed"] = true
      touch("financial_consent.assignment_of_benefits_signed")
    end
    if @lower.match?(/medicare\s+covers?\s+(100%|all|everything)/)
      eval_root["financial_consent"]["medicare_coverage_explained"] = true
      touch("financial_consent.medicare_coverage_explained")
    end
    if @lower.match?(/acknowledged?\s+(liability|responsibility)|understands?\s+they\s+are\s+(liable|responsible)/)
      eval_root["financial_consent"]["aob_liability_acknowledged"] = true
      touch("financial_consent.aob_liability_acknowledged")
    end

    # LCD signals — append any hits to criteria_met
    lcd = eval_root["medicare_lcd_criteria"]["criteria_met"] ||= []
    add_lcd = ->(crit) { lcd << crit unless lcd.include?(crit); touch("medicare_lcd_criteria.criteria_met") }
    add_lcd.call("PPS <=70%")              if eval_root.dig("functional_decline", "pps_score")&.match?(/\b[1-7]?\d\s*%?/) && eval_root["functional_decline"]["pps_score"].to_s.scan(/\d+/).first.to_i <= 70
    add_lcd.call("Weight loss >=10% in 6mo") if eval_root.dig("nutritional_decline", "percent_weight_loss_6mo").to_s.match?(/^(1[0-9]|[2-9]\d)%/)
    add_lcd.call("Albumin <2.5")            if eval_root.dig("nutritional_decline", "albumin_level").to_f != 0 && eval_root["nutritional_decline"]["albumin_level"].to_f < 2.5
    add_lcd.call("Dyspnea at rest")          if eval_root.dig("other_symptoms", "dyspnea") == "at rest"
    add_lcd.call("Dependence in >=3 ADLs")   if (adls.values.count { |v| v.to_s.present? && v != "" }) >= 3

    # Keep the raw text as supporting documentation (clinician's own words)
    eval_root["medicare_lcd_criteria"]["supporting_documentation"] = @text.strip if @text.strip.length > 0 && eval_root["medicare_lcd_criteria"]["supporting_documentation"].to_s.strip.empty?

    Result.new(json: @base, fields_updated: @updated.uniq)
  end

  private

  def touch(path)
    @updated << path
  end
end
