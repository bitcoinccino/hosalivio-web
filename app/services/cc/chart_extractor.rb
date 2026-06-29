module Cc
  # Turns a clinician's plain-language CC shift dictation into the structured
  # nested-attributes hash that CcIntervalChart accepts — for HUMAN REVIEW, never
  # auto-commit. Governed by the Continuous Care protocol (PIE, military time,
  # valid pain levels, nurse-vs-caregiver med source). Returns {} on any failure
  # so the controller just falls back to a blank form.
  class ChartExtractor
    MAX_TOKENS = 2000

    PPE_KEYS    = %w[universal_precautions gown_or_apron face_shield_or_goggles mask
                     n95_mask contact_isolation airborne_isolation droplet_isolation].freeze
    VITALS_KEYS = %w[recorded_at temperature pulse blood_pressure respiration
                     intake_details output_diapers bowel_movement].freeze
    POC_KEYS    = %w[ref_number symptom med_name_and_dose med_source initial_time
                     post_time initial_level post_level response_to_care].freeze
    CS_KEYS     = %w[drug_name count_at_start count_at_end].freeze
    TIME_FIELDS = %w[recorded_at initial_time post_time].freeze

    def self.call(patient:, dictation:, role: nil)
      new(patient, dictation, role).call
    end

    def initialize(patient, dictation, role)
      @patient   = patient
      @dictation = dictation.to_s.strip
      @role      = role.to_s
    end

    def call
      return {} if @dictation.empty?
      raw = request_claude || request_oai(:openai) || request_oai(:openrouter)
      return {} if raw.blank?
      sanitize(parse(raw))
    rescue => e
      Rails.logger.warn("[Cc::ChartExtractor] #{e.class}: #{e.message}")
      {}
    end

    private

    SYSTEM = <<~SYS.freeze
      You convert a hospice Continuous Care shift dictation into structured JSON
      for a clinician to review and sign. Output ONLY a JSON object (no prose,
      no markdown fences) with this exact shape:

      {
        "date_of_shift": "YYYY-MM-DD or null",
        "shift_start_time": "HHMM or null",
        "shift_end_time":   "HHMM or null",
        "ppe": { "mask": true, "universal_precautions": true, ... },
        "cc_vitals_records_attributes": [
          { "recorded_at":"HHMM","temperature":98.6,"pulse":72,
            "blood_pressure":"120/80","respiration":18,"intake_details":"",
            "output_diapers":"","bowel_movement":"" } ],
        "cc_poc_interventions_attributes": [
          { "ref_number":"","symptom":"","med_name_and_dose":"",
            "med_source":"nurse|caregiver","initial_time":"HHMM",
            "initial_level":"0-10 or None|Mild|Moderate|Severe",
            "post_time":"HHMM","post_level":"...","response_to_care":"..." } ],
        "cc_controlled_substance_counts_attributes": [
          { "drug_name":"","count_at_start":0,"count_at_end":0 } ]
      }

      RULES (Continuous Care protocol):
      - Military time, HHMM (e.g. 0800, 1400, 2100).
      - PIE: symptom = the Problem; med/intervention = the Intervention;
        response_to_care = the Evaluation (e.g. "Effective", "Ineffective").
      - initial_level / post_level MUST be a 0-10 number OR one of
        None, Mild, Moderate, Severe.
      - med_source: "caregiver" when the family/home-aide gave the dose, else
        "nurse".
      - GROUND EVERYTHING in the dictation. Do NOT invent vitals, doses, times,
        or counts. Omit fields you weren't told. Omit empty arrays.
    SYS

    def user_prompt
      "PATIENT: #{@patient.full_name} (MR# #{@patient.mrn})\n" \
      "CHARTING ROLE: #{@role.presence || 'nurse'}\n\nSHIFT DICTATION:\n#{@dictation}"
    end

    def request_claude
      return nil unless HosalivioBrain.valid_key?(ENV["ANTHROPIC_API_KEY"])
      uri = URI(HosalivioBrain::CLAUDE_URL)
      req = Net::HTTP::Post.new(uri)
      req["content-type"]      = "application/json"
      req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
      req["anthropic-version"] = HosalivioBrain::CLAUDE_VERSION
      req.body = { model: HosalivioBrain::CLAUDE_MODEL, max_tokens: MAX_TOKENS,
                   system: SYSTEM, messages: [ { role: "user", content: user_prompt } ] }.to_json
      resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
      return nil unless resp.code.to_i == 200
      JSON.parse(resp.body).dig("content", 0, "text").to_s
    end

    # OpenAI-compatible call, shared by :openai and :openrouter (GLM). Returns
    # nil when that provider's key is missing so the chain falls through.
    def request_oai(provider)
      url, key_env, model =
        case provider
        when :openrouter then [ HosalivioBrain::OPENROUTER_URL, "OPENROUTER_API_KEY", HosalivioBrain::OPENROUTER_MODEL ]
        else                  [ HosalivioBrain::OPENAI_URL, "OPENAI_API_KEY", HosalivioBrain::OPENAI_MODEL ]
        end
      return nil unless HosalivioBrain.valid_key?(ENV[key_env])
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req["content-type"]  = "application/json"
      req["authorization"] = "Bearer #{ENV.fetch(key_env)}"
      if provider == :openrouter
        req["HTTP-Referer"] = ENV.fetch("OPENROUTER_REFERER", "https://hosalivio.com")
        req["X-Title"]      = "HosAlivio"
      end
      req.body = { model: model, max_tokens: MAX_TOKENS,
                   messages: [ { role: "system", content: SYSTEM },
                               { role: "user", content: user_prompt } ] }.to_json
      resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
      return nil unless resp.code.to_i == 200
      JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s
    end

    def parse(text)
      JSON.parse(text.to_s.sub(/\A```(?:json)?\s*/m, "").sub(/\s*```\z/m, "").strip)
    end

    # Whitelist every key (the LLM output is untrusted), normalize times to
    # HH:MM, flatten ppe into top-level booleans. Leaves invalid levels as-is so
    # the model validation surfaces them for the clinician to fix.
    def sanitize(h)
      return {} unless h.is_a?(Hash)
      out = {}
      out[:date_of_shift]    = h["date_of_shift"].presence
      out[:shift_start_time] = mil(h["shift_start_time"])
      out[:shift_end_time]   = mil(h["shift_end_time"])
      if h["ppe"].is_a?(Hash)
        PPE_KEYS.each { |k| out[k.to_sym] = true if truthy?(h["ppe"][k]) }
      end
      out[:cc_vitals_records_attributes]              = rows(h["cc_vitals_records_attributes"], VITALS_KEYS)
      out[:cc_poc_interventions_attributes]           = rows(h["cc_poc_interventions_attributes"], POC_KEYS) do |r|
        r[:med_source] = %w[nurse caregiver].include?(r[:med_source].to_s) ? r[:med_source] : "nurse"
      end
      out[:cc_controlled_substance_counts_attributes] = rows(h["cc_controlled_substance_counts_attributes"], CS_KEYS)
      out.compact
    end

    def rows(arr, keys)
      return nil unless arr.is_a?(Array)
      built = arr.filter_map do |raw|
        next unless raw.is_a?(Hash)
        row = {}
        keys.each do |k|
          v = raw[k]
          next if v.nil? || v == ""
          row[k.to_sym] = TIME_FIELDS.include?(k) ? mil(v) : v
        end
        yield(row) if block_given?
        row.presence
      end
      built.presence
    end

    # "1400" / "14:00" / "2:05 pm"ish → "HH:MM"; nil when unparseable/blank.
    def mil(t)
      s = t.to_s.strip
      return nil if s.empty?
      if (m = s.match(/\A(\d{1,2}):?(\d{2})\z/))
        "#{m[1].rjust(2, '0')}:#{m[2]}"
      else
        s
      end
    end

    def truthy?(v) = [ true, "true", 1, "1", "yes" ].include?(v)
  end
end
