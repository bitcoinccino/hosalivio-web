# Schema + clinical validity check for Pascal's pre-admit JSON output.
# Gatekeeper between AgentBrain and AgentTriager#write_pre_admit_eval.
#
# Returns a Result struct with :ok? + :errors + :warnings. Never raises.
# Errors block certification; warnings surface in the UI but don't block.
class PreAdmitValidator
  Result = Struct.new(:ok?, :errors, :warnings, :cleaned_json, keyword_init: true)

  REQUIRED_SECTIONS = %w[general functional_decline nutritional_decline cognitive_decline
                          other_symptoms equipment diagnosis medicare_lcd_criteria
                          billing final_review
                          informed_consent election_of_benefit financial_consent].freeze

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
    check_informed_consent
    check_election_of_benefit
    check_financial_consent

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

  # Consent predicate: family must have AGREED to stop curative treatment.
  # This is the core of the Medicare Hospice Benefit trade-off. Esther cannot
  # certify without it. Missing or false = blocking error.
  def check_informed_consent
    ic = eval_root["informed_consent"] || {}
    if ic["family_agrees_to_stop_curative"] != true
      @errors << "informed_consent.family_agrees_to_stop_curative must be true. This is the core of the Medicare Hospice Benefit and the legal predicate for MD certification."
    end
    if ic["services_explained"] != true
      @warnings << "informed_consent.services_explained not confirmed. CMS COPs require documented service explanation."
    end
    if ic["levels_of_care_explained"] != true
      @warnings << "informed_consent.levels_of_care_explained not confirmed. Family must be told about RHC / CHC / GIP / Respite."
    end
    if ic["questions_answered"] != true
      @warnings << "informed_consent.questions_answered not confirmed. 'Opportunity to ask questions' is a specific CMS element."
    end
  end

  # Election of Benefit: Medicare Hospice Election Statement (MHES) must be
  # signed and a concrete election date captured. NOE filing depends on this.
  def check_election_of_benefit
    eob = eval_root["election_of_benefit"] || {}
    if eob["mhes_signed"] != true
      @errors << "election_of_benefit.mhes_signed must be true before certification. The Medicare Hospice Election Statement is the legal admission document."
    end
    if eob["election_effective_date"].to_s.strip.empty?
      @errors << "election_of_benefit.election_effective_date is required. NOE filing deadline starts from this date."
    end
    if eob["primary_decision_maker_name"].to_s.strip.empty?
      @warnings << "election_of_benefit.primary_decision_maker_name is empty. Capture who signed (patient, spouse, POA, etc.) for audit trail."
    end
  end

  # Financial consent: Assignment of Benefits signed, and if the patient is
  # heading to a facility, the Medicaid room-and-board form is flagged.
  def check_financial_consent
    fc = eval_root["financial_consent"] || {}
    if fc["assignment_of_benefits_signed"] != true
      @errors << "financial_consent.assignment_of_benefits_signed must be true. Without AOB the agency cannot bill Medicare directly and the signer is unprotected on double-billing."
    end
    if fc["aob_liability_acknowledged"] != true
      @warnings << "financial_consent.aob_liability_acknowledged not confirmed. Confirm signer understood they are liable for billing disputes."
    end
    if fc["medicaid_form_needed"] == true && fc["medicaid_form_signed"] != true
      @errors << "financial_consent.medicaid_form_signed must be true when medicaid_form_needed is true. Patient going to a nursing facility needs the R&B form to avoid self-pay bills."
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
