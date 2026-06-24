module PreAdmitEvalsHelper
  # Strings the extractor emits to mean "nothing found" — treated as blank so
  # empty fields and sections drop out instead of showing noise.
  PLACEHOLDER_VALUES = [
    "—", "-", "n/a", "na", "none", "none reported", "no specific finding reported",
    "not assessed", "not reported", "not documented", "unknown", "not applicable", "tbd"
  ].freeze

  def eval_blank?(value)
    s = value.to_s.strip.downcase
    s.empty? || PLACEHOLDER_VALUES.include?(s)
  end

  def eval_present?(value)
    !eval_blank?(value)
  end

  # Common hospice DME the RN can document a need for. Suggestions derived
  # from the eval's clinical signals get merged in and flagged so the RN can
  # accept them with a tap.
  DME_CATALOG = [
    "Hospital bed", "Oxygen concentrator", "Wheelchair", "Walker",
    "Bedside commode", "Hoyer lift", "Nebulizer", "Suction machine"
  ].freeze

  # Heuristic, advisory DME suggestions keyed by label → short reason.
  # Reads the eval's functional + symptom signals. The RN always confirms.
  def suggested_dme(eval)
    fd       = eval.functional_decline
    sx       = eval.other_symptoms
    dyspnea  = (sx["dyspnea"].is_a?(Hash) ? sx["dyspnea"]["severity"] : sx["dyspnea"]).to_s.strip
    mobility = fd["mobility"].to_s.downcase
    adl      = fd["adl_dependencies"].is_a?(Hash) ? fd["adl_dependencies"] : {}
    fall     = fd["fall_history"].to_s.strip
    pps      = eval.pps_score.to_i

    out = {}
    out["Oxygen concentrator"] = "dyspnea (#{dyspnea})" if dyspnea.present?
    if (pps.positive? && pps <= 40) || mobility.match?(/bed/)
      out["Hospital bed"] = pps.positive? ? "functional decline · PPS #{pps}%" : "bedbound / limited mobility"
    end
    if (pps.positive? && pps <= 50) || %w[assist dependent].include?(adl["transferring"].to_s.downcase) || mobility.match?(/wheel|bed/)
      out["Wheelchair"] = "limited mobility / transfer assistance"
    end
    out["Bedside commode"] = "toileting assistance" if %w[assist dependent].include?(adl["toileting"].to_s.downcase)
    out["Walker"] = "fall history" if fall.present? && !mobility.match?(/bed/)
    out
  end

  # Ordered checkbox list for the DME section: every already-selected item,
  # every fresh suggestion, then the rest of the catalog. Each row carries
  # whether it's AI-recommended (+ why) and whether it should start checked.
  def dme_options(eval)
    selected  = Array(eval.general["dme_needs"]).map(&:to_s)
    suggested = suggested_dme(eval)
    (selected + suggested.keys + DME_CATALOG).uniq.map do |label|
      {
        label:       label,
        recommended: suggested.key?(label),
        reason:      suggested[label],
        selected:    selected.include?(label) || suggested.key?(label)
      }
    end
  end
end
