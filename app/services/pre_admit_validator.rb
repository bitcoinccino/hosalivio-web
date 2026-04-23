# Schema + clinical validity check for Pascal's pre-admit JSON output.
# Gatekeeper between AgentBrain and AgentTriager#write_pre_admit_eval.
#
# Returns a Result struct with :ok? + :errors + :warnings. Never raises.
# Errors block certification; warnings surface in the UI but don't block.
class PreAdmitValidator
  Result = Struct.new(:ok?, :errors, :warnings, :cleaned_json, keyword_init: true)

  REQUIRED_SECTIONS = %w[general functional_decline nutritional_decline cognitive_decline
                          other_symptoms equipment diagnosis medicare_lcd_criteria
                          billing final_review].freeze

  ICD10_FORMAT = /\A[A-Z]\d{2}(?:\.\w{1,4})?\z/

  # Non-exhaustive, but the common hospice-eligibility codes we seeded in
  # db/seeds_icd10.rb all map to Medicare LCD-supported categories. If the
  # primary_icd10 isn't here, we warn (not block) — eligibility still
  # depends on documented decline, not code alone.
  HOSPICE_ELIGIBLE_CATEGORIES = %w[cancer cardiac pulmonary neuro renal infectious debility].freeze

  def self.call(json)
    new(json).call
  end

  def initialize(json)
    @json     = json.is_a?(Hash) ? json : {}
    @errors   = []
    @warnings = []
  end

  def call
    check_envelope
    check_sections
    check_primary_icd10
    check_lcd_support
    check_billing_level

    Result.new(
      ok?:          @errors.empty?,
      errors:       @errors,
      warnings:     @warnings,
      cleaned_json: normalize(@json)
    )
  end

  private

  def eval_root
    @json["pre_admit_eval"] || {}
  end

  def check_envelope
    @errors << "Missing top-level 'pre_admit_eval' key." unless @json.key?("pre_admit_eval")
  end

  def check_sections
    missing = REQUIRED_SECTIONS - eval_root.keys
    missing.each { |s| @errors << "Missing section '#{s}' in pre_admit_eval." }
  end

  def check_primary_icd10
    dx = eval_root["diagnosis"] || {}
    code = dx["primary_icd10"].to_s.strip.upcase
    return if code.empty? # empty is allowed per the never-hallucinate rule

    unless code.match?(ICD10_FORMAT)
      @errors << "primary_icd10 '#{code}' is not a valid ICD-10 format."
      return
    end

    # Cross-check against our seed. If the code is not in the seed, warn but
    # don't block — Pascal may have entered a legitimate code we haven't
    # explained for families yet.
    explanation = Icd10Explanation.lookup(code)
    if explanation.nil?
      @warnings << "primary_icd10 '#{code}' is not in the family-explanation seed. Add it to db/seeds_icd10.rb so families see a plain-English tooltip."
    elsif !HOSPICE_ELIGIBLE_CATEGORIES.include?(explanation.category.to_s)
      @warnings << "primary_icd10 '#{code}' category '#{explanation.category}' is not on our hospice-eligibility list. Verify LCD support."
    end
  end

  def check_lcd_support
    lcd = eval_root["medicare_lcd_criteria"] || {}
    criteria = Array(lcd["criteria_met"])
    supporting = lcd["supporting_documentation"].to_s.strip

    if criteria.empty? && supporting.empty?
      @warnings << "No Medicare LCD criteria documented. Esther cannot certify without at least one criterion or supporting text."
    end
  end

  def check_billing_level
    billing = eval_root["billing"] || {}
    levels = %w[gip_criteria_met respite_criteria_met continuous_care_criteria_met routine_home_care]
    chosen = levels.select { |k| billing[k] == true }

    if chosen.empty?
      @errors << "At least one level of care must be true in billing (routine_home_care defaults true)."
    elsif chosen.size > 1 && !chosen.include?("routine_home_care")
      @warnings << "Multiple elevated levels of care flagged: #{chosen.inspect}. Confirm with MD before certifying."
    end
  end

  def normalize(json)
    # Shallow deep-stringify keys + trim string values. Non-destructive.
    return json unless json.is_a?(Hash)
    json.deep_transform_keys(&:to_s).deep_transform_values do |v|
      v.is_a?(String) ? v.strip : v
    end
  end
end
