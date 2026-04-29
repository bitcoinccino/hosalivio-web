# Extracts a hospice Pre-Admit Eval JSON from a clinician-dictated
# visit narrative, in the section-based shape that maps 1:1 to the
# Final Review UI (Header / General Comments / Diagnosis / Current
# Medications / Other Symptoms / Cognitive Decline / Nutritional
# Decline / Functional Decline / General).
#
# Conservative by design: any field not explicitly mentioned in the
# narrative is left nil rather than inferred. Pascal's SOUL's never-
# infer rule is the law. The header block is server-populated from
# the visit + patient + clinician (no extraction needed).
#
# Caller passes in:
#   narrative      — string the clinician dictated
#   existing_json  — current pre_admit_evals.raw_json (preserves
#                    fields the clinician already filled in)
#   visit          — Visit instance (used for header + clinician)
#   patient        — Patient instance (used for header + diagnosis)
#
# Returns Result(json:, fields_updated:) where json is a deep-merged
# hash with the new pre_admit_eval shape and fields_updated is the
# list of dotted paths the extractor touched this run.

class PreAdmitNarrativeExtractor
  Result = Struct.new(:json, :fields_updated, keyword_init: true)

  def self.call(narrative:, existing_json: nil, visit: nil, patient: nil)
    new(narrative: narrative, existing_json: existing_json, visit: visit, patient: patient).call
  end

  def initialize(narrative:, existing_json: nil, visit: nil, patient: nil)
    @text     = narrative.to_s
    @lower    = @text.downcase
    @base     = existing_json.is_a?(Hash) ? existing_json.deep_dup : {}
    @visit    = visit
    @patient  = patient
    @updated  = []
  end

  def call
    eval_root = (@base["pre_admit_eval"] ||= {})

    populate_header(eval_root)
    populate_general_comments(eval_root)
    populate_diagnosis(eval_root)
    populate_other_symptoms(eval_root)
    populate_cognitive_decline(eval_root)
    populate_nutritional_decline(eval_root)
    populate_functional_decline(eval_root)
    populate_general(eval_root)
    populate_lcd_criteria(eval_root)

    # LLM gap-fill pass for free-text fields heuristics can't reach
    # (chief_complaint, HPI, fall_history, equipment status, RN
    # final_review, etc.). Runs only when the brain is configured.
    # Failures are non-blocking — heuristic-extracted fields stay.
    apply_llm_gap_fill(eval_root)

    Result.new(json: @base, fields_updated: @updated.uniq)
  end

  private

  # Sends the polished narrative + the partially-populated eval to
  # HosalivioBrain.fill_eval_gaps. The brain returns a deltas hash
  # with new fields only (it never overwrites populated values).
  # We deep_merge those deltas into eval_root and stamp the touched
  # paths so the controller's "Synced N fields" toast counts them.
  def apply_llm_gap_fill(eval_root)
    return if @text.to_s.strip.length < 80  # not worth the call on stub narratives

    deltas = HosalivioBrain.fill_eval_gaps(narrative: @text, partial_json: { "pre_admit_eval" => eval_root })
    return if deltas.blank?

    deltas.each do |section, fields|
      next unless fields.is_a?(Hash)
      eval_root[section] ||= {}
      fields.each do |key, value|
        # Skip fields the heuristics already filled. The prompt asks
        # the brain not to return them, but defense-in-depth.
        existing = eval_root[section][key]
        already_present = case existing
                          when nil       then false
                          when ""        then false
                          when Array     then existing.any?
                          when Hash      then existing.values.compact_blank.any?
                          else                true
                          end
        next if already_present

        # For nested hashes (e.g., general.equipment), merge per-leaf
        # rather than replacing the whole sub-object.
        if value.is_a?(Hash) && existing.is_a?(Hash)
          existing.merge!(value)
        else
          eval_root[section][key] = value
        end
        touch("#{section}.#{key}")
      end
    end
  rescue => e
    Rails.logger.warn("[PreAdmitNarrativeExtractor#apply_llm_gap_fill] #{e.class}: #{e.message}")
  end

  # ── HEADER (server-populated, not extracted) ─────────────────────

  def populate_header(eval_root)
    h = (eval_root["header"] ||= {})
    if @patient
      h["patient_name"] = @patient.full_name if h["patient_name"].to_s.empty?
      h["dob"]          = @patient.dob.iso8601 if h["dob"].to_s.empty? && @patient.dob.present?
      h["mrn"]          = @patient.mrn if h["mrn"].to_s.empty?
      h["start_of_care_date"] = @patient.hospice_election_date&.iso8601 if h["start_of_care_date"].to_s.empty?
    end
    if @visit
      h["date_of_visit"]   = @visit.started_at&.to_date&.iso8601 || @visit.scheduled_at&.to_date&.iso8601 if h["date_of_visit"].to_s.empty?
      h["visit_type"]      = @visit.visit_type.to_s.tr("_", " ").capitalize if h["visit_type"].to_s.empty?
      if @visit.user
        clinician_role = (@visit.user.role_names & %w[rn md sw chaplain aide don]).first&.upcase
        h["clinician_name"] = [@visit.user.full_name, clinician_role].compact.join(", ") if h["clinician_name"].to_s.empty?
      end
    end
    touch("header") if h.values.any?(&:present?)
  end

  # ── GENERAL COMMENTS ─────────────────────────────────────────────

  def populate_general_comments(eval_root)
    gc = (eval_root["general_comments"] ||= {})
    if gc["narrative_summary"].to_s.empty? && @text.strip.length.positive?
      gc["narrative_summary"] = @text.strip
      touch("general_comments.narrative_summary")
    end
    if @lower.match?(/\b(safety risk|fall risk|elopement|home unsafe)\b/) && Array(gc["immediate_safety_risks"]).empty?
      gc["immediate_safety_risks"] = ["Identified during assessment, see narrative"]
      touch("general_comments.immediate_safety_risks")
    end
    if gc["family_caregiver_status"].to_s.empty?
      if @lower.match?(/(family\s+(is\s+)?supportive|family\s+present|spouse\s+(is\s+)?supportive|caregiver\s+available)/)
        gc["family_caregiver_status"] = "Supportive"
        touch("general_comments.family_caregiver_status")
      elsif @lower.match?(/(caregiver\s+overwhelmed|caregiver\s+distress|family\s+conflict|no\s+caregiver)/)
        gc["family_caregiver_status"] = "Strained"
        touch("general_comments.family_caregiver_status")
      end
    end
  end

  # ── DIAGNOSIS ────────────────────────────────────────────────────

  def populate_diagnosis(eval_root)
    dx = (eval_root["diagnosis"] ||= {})
    if @patient && (dx["primary_terminal_diagnosis"].is_a?(Hash) ? dx["primary_terminal_diagnosis"]["description"].to_s.empty? : true)
      icd10 = @patient.primary_diagnosis.to_s[/\b([A-Z]\d{2}(?:\.\d{1,3})?)\b/, 1]
      desc  = @patient.primary_diagnosis.to_s.sub(/\s*\(?ICD-?10\s*[:\-]?\s*[A-Z]\d{2}(?:\.\d{1,3})?\)?/i, "").strip
      dx["primary_terminal_diagnosis"] = { "description" => desc, "icd10" => icd10 }.compact
      touch("diagnosis.primary_terminal_diagnosis")
    end
    if @patient && Array(dx["secondary_diagnoses"]).empty? && @patient.secondary_diagnoses.present?
      dx["secondary_diagnoses"] = @patient.secondary_diagnoses.to_s.split(/[,;]\s*/).map { |d|
        icd10 = d[/\b([A-Z]\d{2}(?:\.\d{1,3})?)\b/, 1]
        desc  = d.sub(/\s*\(?ICD-?10\s*[:\-]?\s*[A-Z]\d{2}(?:\.\d{1,3})?\)?/i, "").strip
        { "description" => desc, "icd10" => icd10 }.compact
      }
      touch("diagnosis.secondary_diagnoses")
    end
    dx["hospice_eligible"] = true if dx["hospice_eligible"].nil? && lcd_eligible?(eval_root)
  end

  # ── OTHER SYMPTOMS ───────────────────────────────────────────────

  def populate_other_symptoms(eval_root)
    sx = (eval_root["other_symptoms"] ||= {})

    pain = (sx["pain"] ||= {})
    if (m = @lower.match(/pain\s*(?:score|level|of|at|:)?\s*(\d{1,2})(?:\s*\/\s*10)?/)) && m[1].to_i.between?(0, 10)
      pain["score"] ||= m[1].to_i
      touch("other_symptoms.pain.score")
    end
    %w[lower\sback chest abdomen abdominal head neck shoulder hip knee leg arm].each do |loc|
      if pain["location"].to_s.empty? && @lower.match?(/\b#{loc}\b/)
        pain["location"] = loc.gsub('\\s', " ")
        touch("other_symptoms.pain.location")
        break
      end
    end

    dyspnea = (sx["dyspnea"] ||= {})
    if dyspnea["severity"].to_s.empty?
      dyspnea["severity"] =
        if @lower.match?(/dyspnea\s+at\s+rest|short(?:ness)?\s+of\s+breath\s+at\s+rest/) then "at rest"
        elsif @lower.match?(/dyspnea\s+on\s+exertion|sob\s+on\s+exertion|short(?:ness)?\s+of\s+breath\s+on\s+exertion/) then "on exertion"
        elsif @lower.match?(/\b(dyspnea|shortness\s+of\s+breath|sob)\b/) then "present"
        end
      touch("other_symptoms.dyspnea.severity") if dyspnea["severity"]
    end

    gi = (sx["gi_symptoms"] ||= {})
    # 'Nausea none' / 'nausea: none' / 'no nausea' all mean none.
    gi["nausea"]       ||= (@lower.match?(/nausea\s*(:\s*)?(none|absent)|no\s+nausea|denies\s+nausea/) ? "none" : "present") if @lower.match?(/\bnausea\b/)
    gi["vomiting"]     ||= (@lower.match?(/vomit\w*\s*(:\s*)?(none|absent)|no\s+vomit|denies\s+vomit/)  ? "none" : "present") if @lower.match?(/\bvomit/)
    gi["constipation"] ||= (@lower.match?(/constipat\w*\s*(:\s*)?(none|absent)|no\s+constipat|denies\s+constipat/) ? "none" : "present") if @lower.match?(/\bconstipat/)
    touch("other_symptoms.gi_symptoms") if gi.values.any?

    psy = (sx["psychosocial"] ||= {})
    psy["anxiety"]    ||= "present" if @lower.match?(/\banxious|\banxiety\b/)
    psy["depression"] ||= "present" if @lower.match?(/\bdepress/)
    psy["agitation"]  ||= "present" if @lower.match?(/\bagitat/)
    touch("other_symptoms.psychosocial") if psy.values.any?
  end

  # ── COGNITIVE DECLINE ────────────────────────────────────────────

  def populate_cognitive_decline(eval_root)
    cd = (eval_root["cognitive_decline"] ||= {})
    if cd["mental_status"].to_s.empty?
      if @lower.match?(/alert\s+(?:and\s+)?orient(?:ed)?\s*(?:x\s*\d|to\s+(?:person|place|time|situation))/)
        cd["mental_status"] = @text[/[Aa]lert[^\.]{0,80}orient(?:ed)?[^\.]{0,80}\./].to_s.strip.presence || "Alert and oriented"
        touch("cognitive_decline.mental_status")
      elsif @lower.match?(/confus(?:ed|ion)|disoriented|delirium/)
        cd["mental_status"] = "Confused / disoriented"
        touch("cognitive_decline.mental_status")
      elsif @lower.match?(/unresponsive|comatose/)
        cd["mental_status"] = "Unresponsive"
        touch("cognitive_decline.mental_status")
      end
    end
    if (m = @lower.match(/\bfast\s*(?:score|stage|of|:)?\s*(\d[a-c]?)/i)) && cd["fast_score"].to_s.empty?
      cd["fast_score"] = m[1].upcase
      touch("cognitive_decline.fast_score")
    end
    if (m = @lower.match(/\b(bims|mmse)\s*(?:score|of|=|:)?\s*(\d{1,2})/)) && cd["bims_mmse_score"].to_s.empty?
      cd["bims_mmse_score"] = m[2].to_i
      touch("cognitive_decline.bims_mmse_score")
    end
  end

  # ── NUTRITIONAL DECLINE ──────────────────────────────────────────

  def populate_nutritional_decline(eval_root)
    nd = (eval_root["nutritional_decline"] ||= {})
    if (m = @lower.match(/(?:current\s+weight|weighs?)\s*(?:is|of|=|:)?\s*(\d{2,3})\s*(?:lbs?|pounds?)/)) && nd["current_weight_lbs"].to_s.empty?
      nd["current_weight_lbs"] = m[1].to_i
      touch("nutritional_decline.current_weight_lbs")
    end
    if (m = @text.match(/lost\s+(\d{1,3})\s*(lbs?|pounds?)\s+(?:in|over)\s+(?:the\s+)?(\d{1,3})\s*(days?|weeks?|months?)/i))
      nd["weight_loss_lbs"]      ||= m[1].to_i
      nd["weight_loss_timeframe"] ||= "#{m[3]} #{m[4].downcase}"
      touch("nutritional_decline.weight_loss_lbs")
    end
    # Catches both '8% weight loss' and 'weight loss 8.4%' phrasings.
    if (m = @lower.match(/(?:weight\s+loss|loss)\s+(?:of\s+)?(\d{1,2}(?:\.\d)?)\s*%/) ||
            @lower.match(/(\d{1,2}(?:\.\d)?)\s*%\s+(?:weight\s+loss|loss)/))
      nd["weight_loss_pct"] ||= m[1].to_f
      touch("nutritional_decline.weight_loss_pct")
    end
    if (m = @lower.match(/albumin\s*(?:of|is|=|:)?\s*(\d+(?:\.\d+)?)/))
      nd["albumin_g_dl"] ||= m[1].to_f
      touch("nutritional_decline.albumin_g_dl")
    end
    if nd["intake"].to_s.empty?
      nd["intake"] =
        if @lower.match?(/\b(npo|not eating|refusing food|no oral intake)\b/) then "None / NPO"
        elsif @lower.match?(/\b(poor (intake|appetite)|barely eating|minimal intake)\b/) then "Poor"
        elsif @lower.match?(/\b(fair (intake|appetite)|reduced (intake|appetite))\b/) then "Fair"
        elsif @lower.match?(/\b(good (intake|appetite)|eating well)\b/) then "Good"
        end
      touch("nutritional_decline.intake") if nd["intake"]
    end
  end

  # ── FUNCTIONAL DECLINE ───────────────────────────────────────────

  def populate_functional_decline(eval_root)
    fd = (eval_root["functional_decline"] ||= {})

    # PPS is structured: { score, source, justification }.
    # When the clinician says a number, we capture it and stamp
    # source: 'clinician' with the exact phrase as justification.
    # Calculated PPS (Leftward Precedence over the five domains) is
    # planned via HosalivioBrain.calculate_pps; until then the
    # calculator path stays a placeholder so the structure is stable.
    if fd["pps"].nil? || (fd["pps"].is_a?(Hash) && fd["pps"]["score"].to_i.zero?)
      if (m = @lower.match(/\bpps\s*(?:is|at|of|=|:)?\s*(\d{1,3})\s*%?/)) && m[1].to_i.between?(10, 100)
        clinician_phrase = @text[/\b[Pp][Pp][Ss][^\.]{0,40}\b/].to_s.strip.presence ||
                           "PPS #{m[1]}"
        fd["pps"] = {
          "score"         => m[1].to_i,
          "source"        => "clinician",
          "justification" => clinician_phrase
        }
        touch("functional_decline.pps")
      else
        # Clinician didn't speak a number. Ask the brain to score by
        # Leftward Precedence over the five domains. Returns nil if
        # the narrative is too thin to score or no LLM is configured;
        # the Final Review UI then prompts the clinician to enter one.
        calc = HosalivioBrain.calculate_pps(narrative: @text)
        if calc && calc["score"].to_i.between?(10, 100)
          fd["pps"] = calc
          touch("functional_decline.pps")
        end
      end
    elsif fd["pps"].is_a?(Integer)
      # Backfill: an older row stored PPS as a flat integer. Wrap it
      # in the new shape and stamp source: 'clinician' (we have no
      # justification text on file for legacy rows).
      legacy = fd["pps"]
      fd["pps"] = { "score" => legacy, "source" => "clinician", "justification" => "" }
      touch("functional_decline.pps")
    end
    if (m = @lower.match(/\b(?:kps|karnofsky)\s*(?:is|at|of|=|:)?\s*(\d{1,3})\s*%?/)) && m[1].to_i.between?(10, 100)
      fd["kps"] ||= m[1].to_i
      touch("functional_decline.kps")
    end
    if fd["mobility"].to_s.empty?
      fd["mobility"] =
        if @lower.match?(/\bbedbound\b/) then "Bedbound"
        elsif @lower.match?(/bed[\s-]*to[\s-]*chair/) then "Bed-to-chair with assist"
        elsif @lower.match?(/ambulat(?:es|ory|ing)\s+with\s+(assist|walker|cane)/) then "Ambulatory with assist"
        elsif @lower.match?(/ambulat(?:es|ory)/) then "Ambulatory"
        end
      touch("functional_decline.mobility") if fd["mobility"]
    end

    adl = (fd["adl_dependencies"] ||= {})
    %w[bathing dressing feeding toileting transferring].each do |task|
      next unless adl[task].to_s.empty?
      task_re = task == "transferring" ? /transfer/ : Regexp.new(task)
      next unless @lower.match?(task_re)
      adl[task] =
        if @lower.match?(/(total|full)\s+(assist|dependence)\s+(with\s+|in\s+)?#{task[0..5]}/) then "Dependent"
        elsif @lower.match?(/(needs|requires|needs help with)\s+(assist|help)\s+(with\s+)?#{task[0..5]}/) then "Assist"
        elsif @lower.match?(/independent\s+(with\s+|in\s+)?#{task[0..5]}/) then "Independent"
        end
      touch("functional_decline.adl_dependencies.#{task}") if adl[task]
    end
  end

  # ── GENERAL (consents, AD, DME, spiritual) ────────────────────────

  def populate_general(eval_root)
    g = (eval_root["general"] ||= {})
    if g["election_of_benefits_signed"].nil? && @lower.match?(/(signed\s+(the\s+)?(election|mhes|medicare\s+hospice)|election\s+(of\s+benefits?\s+)?signed|mhes\s+signed)/)
      g["election_of_benefits_signed"] = true
      touch("general.election_of_benefits_signed")
    end
    if g["advance_directives"].to_s.empty?
      g["advance_directives"] =
        if @lower.match?(/\bdnr\s*\/\s*dni\b|\bdnr\b.*\bdni\b/) then "DNR / DNI"
        elsif @lower.match?(/\bdnr\b/) then "DNR"
        elsif @lower.match?(/full\s+code/) then "Full code"
        end
      touch("general.advance_directives") if g["advance_directives"]
    end
    if g["patient_rights_reviewed"].nil? && @lower.match?(/(patient(?:'s)?\s+rights\s+(reviewed|explained)|reviewed\s+patient\s+rights)/)
      g["patient_rights_reviewed"] = true
      touch("general.patient_rights_reviewed")
    end
    if g["spiritual_bereavement_risk"].to_s.empty?
      g["spiritual_bereavement_risk"] =
        if @lower.match?(/(complicated grief|high\s+bereavement\s+risk|spiritual\s+distress)/) then "High"
        elsif @lower.match?(/(moderate\s+(spiritual|bereavement))/) then "Moderate"
        elsif @lower.match?(/(low\s+(spiritual|bereavement)|no\s+complicating)/) then "Low"
        end
      touch("general.spiritual_bereavement_risk") if g["spiritual_bereavement_risk"]
    end

    dme = Array(g["dme_needs"]).dup
    {
      "Hospital bed"       => /hospital\s+bed/,
      "Oxygen concentrator" => /oxygen|o2\s+concentrator/,
      "Wheelchair"          => /wheel\s*chair|wheelchair/,
      "Walker"              => /\bwalker\b/,
      "Bedside commode"     => /bedside\s+commode|commode/,
      "Hoyer lift"          => /hoyer|patient\s+lift/
    }.each { |label, rx| dme << label if @lower.match?(rx) && !dme.include?(label) }
    if dme.any?
      g["dme_needs"] = dme
      touch("general.dme_needs")
    end
  end

  # ── LCD criteria (lifted into diagnosis.lcd_criteria_met) ────────

  def populate_lcd_criteria(eval_root)
    dx  = (eval_root["diagnosis"] ||= {})
    fd  = eval_root["functional_decline"] || {}
    nd  = eval_root["nutritional_decline"] || {}
    sx  = eval_root["other_symptoms"]      || {}
    crit = Array(dx["lcd_criteria_met"]).dup

    add = ->(c) { crit << c unless crit.include?(c) }
    pps_score =
      case fd["pps"]
      when Integer then fd["pps"]
      when Hash    then fd["pps"]["score"].to_i
      end
    add.call("PPS ≤ 70%")               if pps_score && pps_score.between?(10, 70)
    add.call("Weight loss ≥ 10% in 6 months") if nd["weight_loss_pct"].to_f >= 10
    add.call("Albumin < 2.5 g/dL")      if nd["albumin_g_dl"].to_f.positive? && nd["albumin_g_dl"].to_f < 2.5
    add.call("Resting dyspnea")         if sx.dig("dyspnea", "severity") == "at rest"
    adl_count = Array(fd.dig("adl_dependencies")&.values).count { |v| v.to_s == "Dependent" || v.to_s == "Assist" }
    add.call("Dependence in ≥ 3 ADLs")  if adl_count >= 3

    if crit.any? && Array(dx["lcd_criteria_met"]) != crit
      dx["lcd_criteria_met"] = crit
      touch("diagnosis.lcd_criteria_met")
    end
  end

  def lcd_eligible?(eval_root)
    Array(eval_root.dig("diagnosis", "lcd_criteria_met")).any?
  end

  def touch(path)
    @updated << path
  end
end
