module Intake
  # Pulls the intake fields a clinician *speaks* during an admission visit out of
  # the polished narrative, so they can be staged for the RN to review and accept
  # into the patient record. Companion to PreAdmitNarrativeExtractor (which owns
  # the clinical eval); this one owns the administrative overlap.
  #
  # Deliberately conservative — a field is only returned when the narrative says
  # it plainly, AND the patient's current value is blank (never overwrites what
  # registration captured). Administrative data that isn't spoken at the bedside
  # (insurance, NPI, policy #, address) is out of scope by design. Values are
  # normalized to the intake form's option lists so an accepted suggestion is a
  # valid select value. Pure/heuristic — no network, unit-testable.
  #
  # Returns { "field" => "value" }. Keys are either Patient columns
  # (code_status, caregiver_relationship, veteran_status) or Patient::INTAKE_KEYS
  # (marital_status, living_arrangements, attending_physician_name).
  class NarrativeExtractor
    REL_MAP = {
      "wife" => "Spouse", "husband" => "Spouse", "spouse" => "Spouse", "partner" => "Partner",
      "daughter" => "Daughter", "son" => "Son", "mother" => "Parent", "father" => "Parent",
      "parent" => "Parent", "sister" => "Sibling", "brother" => "Sibling", "sibling" => "Sibling",
      "granddaughter" => "Grandchild", "grandson" => "Grandchild", "grandchild" => "Grandchild",
      "friend" => "Friend", "guardian" => "Guardian"
    }.freeze

    def self.call(narrative:, patient:)
      new(narrative, patient).call
    end

    def initialize(narrative, patient)
      @text    = narrative.to_s
      @lower   = @text.downcase
      @patient = patient
    end

    def call
      out = {}
      out["marital_status"]           = marital    if marital    && blank_intake?("marital_status")
      out["living_arrangements"]      = living     if living     && blank_intake?("living_arrangements")
      out["attending_physician_name"] = physician  if physician  && blank_intake?("attending_physician_name")
      out["veteran_status"]           = veteran    if veteran    && @patient.veteran_status.blank?
      out["caregiver_relationship"]   = caregiver  if caregiver  && @patient.caregiver_relationship.blank?
      # Only surface a code status when the narrative states a non-default one and
      # the patient is still on the full_code default.
      cs = code_status
      out["code_status"] = cs if cs && cs != "full_code" && @patient.code_status.to_s == "full_code"
      out
    end

    private

    def blank_intake?(key)
      @patient.intake[key].blank?
    end

    def marital
      return "Widowed"   if @lower.match?(/\bwidow(ed|er)?\b/)
      return "Married"   if @lower.match?(/\bmarried\b/)
      return "Divorced"  if @lower.match?(/\bdivorced\b/)
      return "Separated" if @lower.match?(/\bseparated\b/)
      return "Single"    if @lower.match?(/\bsingle\b/)
      nil
    end

    def living
      return "Skilled nursing facility"    if @lower.match?(/\b(skilled nursing|nursing home|snf)\b/)
      return "Assisted living facility"    if @lower.match?(/\bassisted living\b|\balf\b/)
      return "Long-term care facility"     if @lower.match?(/\blong[- ]term care\b|\bltc\b/)
      return "Group home / board & care"   if @lower.match?(/\bgroup home\b|\bboard (and|&) care\b/)
      return "Homeless / unstable housing" if @lower.match?(/\bhomeless\b|\bunstable housing\b/)
      return "Living with family"          if @lower.match?(/\blives? with (family|daughter|son|spouse|wife|husband)\b/)
      return "Private home"                if @lower.match?(/\blives? (at|in) home\b|\bat home\b|\bprivate (home|residence)\b|\bown home\b|\bhome setting\b/)
      nil
    end

    def veteran
      return "Spouse of veteran" if @lower.match?(/\bspouse of (a |an )?veteran\b/)
      return "Not a veteran"     if @lower.match?(/\bnot a veteran\b|\bnon[- ]?veteran\b|\bno military (service|history)\b/)
      if @lower.match?(/\bveteran\b/) ||
         @lower.match?(/\bserved in the (army|navy|air force|marines?|coast guard|military)\b/) ||
         @lower.match?(/\b(us )?(army|navy|air force|marine corps) veteran\b/)
        return "Veteran"
      end
      nil
    end

    def caregiver
      REL_MAP.each do |word, rel|
        near_caregiver = /\b#{word}\b[^.]{0,40}\b(caregiver|caring|cares for)\b/
        caregiver_near = /\b(caregiver|cared for by|care(?:d)? by|primary caregiver is)\b[^.]{0,40}\b#{word}\b/
        return rel if @lower.match?(near_caregiver) || @lower.match?(caregiver_near)
      end
      nil
    end

    def physician
      m = @text.match(/\bDr\.?\s+([A-Z][A-Za-z'’.\-]+(?:\s+[A-Z][A-Za-z'’.\-]+)?)/)
      m && "Dr. #{m[1].strip}"
    end

    def code_status
      return "dnr_dni"      if @lower.match?(/\bdnr\s*\/\s*dni\b|\bdnr and dni\b|\bdni\s*\/\s*dnr\b/)
      return "comfort_only" if @lower.match?(/\bcomfort (care|measures|only)\b/)
      return "dnr"          if @lower.match?(/\bdnr\b|\bdo not resuscitate\b/)
      return "dni"          if @lower.match?(/\bdni\b|\bdo not intubate\b/)
      return "full_code"    if @lower.match?(/\bfull code\b/)
      nil
    end
  end
end
