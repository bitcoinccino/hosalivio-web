# HosAlivio's brain. Routes a family message through an ordered chain of
# providers until one responds: Anthropic Claude, then OpenAI, then a
# regex fallback.
#
# Contract: always returns a hash with these five keys (never raises).
#   { intent:, urgency:, reasoning:, reply:, source: }
#
# The triager doesn't know or care which provider answered. The `source`
# field records it for audit (e.g. "claude:claude-sonnet-4-6",
# "openai:gpt-4o", "fallback:regex") and flows into agent_session_id on
# every downstream write.

require "net/http"
require "json"

class HosalivioBrain
  SOUL_PATH = File.expand_path("~/.openclaw/agents/admission_coordinator/SOUL.md")

  # Claude primary config
  CLAUDE_URL     = "https://api.anthropic.com/v1/messages"
  CLAUDE_VERSION = "2023-06-01"
  CLAUDE_MODEL   = ENV.fetch("HOSALIVIO_BRAIN_MODEL", ENV.fetch("HOSALIVIO_LUCIA_MODEL", "claude-sonnet-4-6"))

  # OpenAI fallback config
  OPENAI_URL   = "https://api.openai.com/v1/chat/completions"
  OPENAI_MODEL = ENV.fetch("HOSALIVIO_BRAIN_OPENAI_MODEL", ENV.fetch("HOSALIVIO_LUCIA_OPENAI_MODEL", "gpt-4o"))

  INTENTS = %w[
    pain_crisis dyspnea decline caregiver_distress transitioning
    med_refill spiritual logistics status_question other
  ].freeze

  URGENCIES = %w[crisis urgent normal].freeze

  # Ordered provider chain. Each returns {intent, urgency, reasoning, reply, source}
  # or raises. `fallback` never raises.
  PROVIDER_CHAIN = %i[claude openai].freeze

  class << self
    def enabled?(provider = nil)
      case provider
      when :claude then valid_key?(ENV["ANTHROPIC_API_KEY"])
      when :openai then valid_key?(ENV["OPENAI_API_KEY"])
      when nil     then PROVIDER_CHAIN.any? { |p| enabled?(p) }
      end
    end

    def call(note:)
      new(note).call
    end

    # Reads a clinician-authored message and decides:
    #   audience  → "family" or "team" (sets clinician_only)
    #   action    → which agent to dispatch (or "no_action")
    #   ack       → short HosAlivio confirmation to post in the team
    #               trail when an action fires
    # Synchronous and never raises (returns a fallback shape).
    def classify_clinician_message(note:, requester:)
      new(note).classify_for(requester)
    end

    private

    def valid_key?(k)
      k = k.to_s.strip
      return false if k.empty?
      # Ignore placeholder strings like "sk-ant-..." or "sk-..."
      return false if k.end_with?("...")
      true
    end
  end

  def initialize(note)
    @note    = note
    @patient = note.patient
  end

  def call
    attempts = []
    PROVIDER_CHAIN.each do |provider|
      next unless self.class.enabled?(provider)
      begin
        return attempt(provider)
      rescue => e
        attempts << "#{provider}=#{e.class}"
        Rails.logger.warn("[HosalivioBrain:#{provider}] #{e.class}: #{e.message}")
      end
    end
    fallback(reason: attempts.empty? ? "no_providers_configured" : attempts.join(","))
  end

  # Clinician-message classification path. Reuses Claude/OpenAI chain
  # but with a different prompt + return shape. Falls back to a regex
  # classifier when no LLM is configured so dev keeps working.
  def classify_for(requester)
    @requester = requester
    PROVIDER_CHAIN.each do |provider|
      next unless self.class.enabled?(provider)
      begin
        raw    = (provider == :claude) ? request_claude_clinician : request_openai_clinician
        parsed = parse(raw).transform_keys(&:to_sym)
        return sanitize_clinician(parsed, "claude:#{CLAUDE_MODEL}".sub("claude", provider.to_s))
      rescue => e
        Rails.logger.warn("[HosalivioBrain.classify_for:#{provider}] #{e.class}: #{e.message}")
      end
    end
    classify_for_regex_fallback
  end

  private

  def attempt(provider)
    raw    = provider == :claude ? request_claude : request_openai
    parsed = parse(raw)
    sanitize(parsed, source_tag(provider))
  end

  def source_tag(provider)
    case provider
    when :claude then "claude:#{CLAUDE_MODEL}"
    when :openai then "openai:#{OPENAI_MODEL}"
    end
  end

  def sanitize(parsed, source)
    {
      intent:    INTENTS.include?(parsed[:intent])    ? parsed[:intent]  : "other",
      urgency:   URGENCIES.include?(parsed[:urgency]) ? parsed[:urgency] : (@note.urgency.presence || "normal"),
      reasoning: parsed[:reasoning].to_s.strip,
      reply:     parsed[:reply].to_s.strip.presence || "I've recorded your message and let the team know. Someone will follow up.",
      source:    source
    }
  end

  # ── Anthropic Claude ───────────────────────────────────────────────

  def request_claude
    uri = URI(CLAUDE_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]      = "application/json"
    req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
    req["anthropic-version"] = CLAUDE_VERSION
    req.body = {
      model:      CLAUDE_MODEL,
      max_tokens: 700,
      system: [
        { type: "text", text: soul_md,           cache_control: { type: "ephemeral" } },
        { type: "text", text: instruction_block }
      ],
      messages: [ { role: "user", content: user_prompt } ]
    }.to_json

    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    raise "Anthropic #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200

    data = JSON.parse(resp.body)
    data.dig("content", 0, "text").to_s
  end

  # ── OpenAI fallback ────────────────────────────────────────────────

  def request_openai
    uri = URI(OPENAI_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]  = "application/json"
    req["authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY")}"
    req.body = {
      model: OPENAI_MODEL,
      max_tokens: 700,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: "#{soul_md}\n\n---\n\n#{instruction_block}" },
        { role: "user",   content: user_prompt }
      ]
    }.to_json

    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    raise "OpenAI #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200

    data = JSON.parse(resp.body)
    data.dig("choices", 0, "message", "content").to_s
  end

  # ── Shared parsing + prompts ───────────────────────────────────────

  def parse(text)
    stripped = text.sub(/\A```(?:json)?\s*/m, "").sub(/\s*```\z/m, "").strip
    JSON.parse(stripped).transform_keys(&:to_sym)
  end

  def soul_md
    @soul_md ||= File.exist?(SOUL_PATH) ? File.read(SOUL_PATH) :
      "You are HosAlivio, an experienced hospice admissions coordinator. Warm, specific, unhurried."
  end

  def instruction_block
    <<~INSTR
      RESPONSE FORMAT — THIS TURN ONLY
      ────────────────────────────────
      You are triaging a single inbound message from a patient's family member.

      Output ONLY a JSON object (no preamble, no markdown fences) with these four keys:

      {
        "intent":    one of #{INTENTS.inspect},
        "urgency":   one of #{URGENCIES.inspect},
        "reasoning": one sentence for the clinical team explaining what you heard and why this classification,
        "reply":     a warm, specific reply to the family in plain language, 2 to 4 sentences, name the clinician you are alerting, be honest about what you do not know
      }

      URGENCY
        crisis  : life or comfort critical right now (uncontrolled pain, dyspnea, active dying signs)
        urgent  : address within hours (meds running out, caregiver distress, moderate symptom change)
        normal  : routine or informational, fine until next scheduled touch

      INTENT VOCABULARY (use these exactly, do not invent new values)
        pain_crisis         : uncontrolled pain or acute symptom the family is alarmed by
        dyspnea             : breathing trouble, air hunger, "can't catch his breath"
        decline             : subtle shift, not eating, more sleeping, "isn't himself", early transition signals
        caregiver_distress  : the family member is overwhelmed or asking for themselves
        transitioning       : signs of imminent dying (mottling, terminal restlessness, cold extremities, visioning)
        med_refill          : out of or running low on a medication
        spiritual           : coping, meaning, faith, fear of dying
        logistics           : equipment, delivery, scheduling, paperwork
        status_question     : "when is the nurse coming?" and similar
        other               : none of the above

      RULES
        - You do NOT give medical advice. You route.
        - Do NOT promise specific ETAs unless you know them. Say "within the hour" or "shortly".
        - If crisis, include this line in your reply: "If this becomes life-threatening, please call 911 — we are not emergency services."
        - Use the patient's first name only once, if appropriate. Do not over-personalize.
    INSTR
  end

  def user_prompt
    <<~USR
      PATIENT CONTEXT
        MRN:               #{@patient.mrn}
        Name:              #{@patient.full_name}
        Age:               #{@patient.age_years}
        Code status:       #{@patient.code_status}
        Primary diagnosis: #{@patient.primary_diagnosis}
        Assigned RN:       #{@patient.assigned_rn&.full_name || "(unassigned)"}
        Assigned MD:       #{@patient.assigned_md&.full_name || "(unassigned)"}
        Chaplain:          #{@patient.assigned_chaplain&.full_name || "(unassigned)"}
        Social worker:     #{@patient.assigned_sw&.full_name || "(unassigned)"}

      FAMILY MESSAGE (source: #{@note.source}, family-declared urgency: #{@note.urgency})
        #{@note.body}
    USR
  end

  # ── Clinician message classifier (LLM) ────────────────────────────

  CLINICIAN_ACTIONS = %w[
    no_action
    pharmacy_comfort_kit
    pharmacy_refill
    chaplain_request
    sw_request
    dme_order
    noe_file
  ].freeze

  def clinician_system_prompt
    <<~SYS
      You are HosAlivio, a hospice care coordination AI. You sit between the
      clinical team and the family inside the patient chat. A clinician just
      typed a message. Your job: classify what to do.

      Output ONLY a JSON object (no preamble, no markdown fences) with these keys:

      {
        "audience": one of ["family", "team"],
        "action":   one of #{CLINICIAN_ACTIONS.inspect},
        "ack":      short confirmation string OR null,
        "reasoning": one sentence
      }

      audience
        family : the clinician is updating the family member directly
                 ('I am on my way', 'she is resting', 'call me if')
        team   : coordination among clinicians, addressed to a teammate, or
                 a delegation request to HosAlivio. Default to team when
                 you are not certain.

      action
        pharmacy_comfort_kit : new comfort kit for the patient
        pharmacy_refill      : refill an existing PRN medication
        chaplain_request     : send the chaplain to the patient
        sw_request           : send the social worker
        dme_order            : equipment (hospital bed, oxygen, walker, etc.)
        noe_file             : file the Notice of Election with insurance
        no_action            : the clinician is not asking for anything to
                               be dispatched. Most messages are no_action.

      ack
        Required when action != no_action. Short, calm, names the role you
        notified. e.g. "Pharmacy notified, refill on the way." or
        "Chaplain handoff queued for tomorrow."
        Use null when action is no_action.

      reasoning
        One sentence for the audit trail explaining your choices.
    SYS
  end

  def clinician_user_prompt
    <<~USR
      PATIENT
        #{@patient.full_name} (#{@patient.mrn})
        Diagnosis: #{@patient.primary_diagnosis}
        Code status: #{@patient.code_status}
        Assigned RN: #{@patient.assigned_rn&.full_name || "(unassigned)"}
        Assigned MD: #{@patient.assigned_md&.full_name || "(unassigned)"}
        Chaplain:    #{@patient.assigned_chaplain&.full_name || "(unassigned)"}
        Social worker: #{@patient.assigned_sw&.full_name || "(unassigned)"}

      CLINICIAN (sender)
        #{@requester&.full_name} (#{(@requester&.role_names || []).join(', ')})

      MESSAGE
        #{@note.body}
    USR
  end

  def request_claude_clinician
    uri = URI(CLAUDE_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]      = "application/json"
    req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
    req["anthropic-version"] = CLAUDE_VERSION
    req.body = {
      model:      CLAUDE_MODEL,
      max_tokens: 400,
      system:     [{ type: "text", text: clinician_system_prompt }],
      messages:   [{ role: "user", content: clinician_user_prompt }]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 20) { |h| h.request(req) }
    raise "Anthropic #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("content", 0, "text").to_s
  end

  def request_openai_clinician
    uri = URI(OPENAI_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]  = "application/json"
    req["authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY")}"
    req.body = {
      model: OPENAI_MODEL,
      max_tokens: 400,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: clinician_system_prompt },
        { role: "user",   content: clinician_user_prompt }
      ]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 20) { |h| h.request(req) }
    raise "OpenAI #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s
  end

  AUDIENCES = %w[family team].freeze

  def sanitize_clinician(parsed, source)
    audience = AUDIENCES.include?(parsed[:audience]) ? parsed[:audience] : "team"
    action   = CLINICIAN_ACTIONS.include?(parsed[:action]) ? parsed[:action] : "no_action"
    ack      = action == "no_action" ? nil : parsed[:ack].to_s.strip.presence
    {
      audience:  audience,
      action:    action,
      ack:       ack,
      reasoning: parsed[:reasoning].to_s.strip,
      source:    source
    }
  end

  # Last-resort regex classifier when no LLM is configured. Matches the
  # ClinicianDispatcher heuristics so dev still works without API keys.
  def classify_for_regex_fallback
    body = @note.body.to_s
    audience = ClinicianDispatcher::FAMILY_UPDATE_RE.match?(body) ? "family" : "team"
    action_intent = nil
    ClinicianDispatcher::INTENT_MAP.each do |pattern, intent|
      if body.match?(pattern)
        action_intent = intent.to_s
        break
      end
    end
    {
      audience:  audience,
      action:    action_intent || "no_action",
      ack:       action_intent ? "Routing your request to the right team member." : nil,
      reasoning: "Regex fallback (no LLM configured).",
      source:    "fallback:regex"
    }
  end

  # Regex fallback. Same return shape so HosalivioTriager doesn't know the difference.
  def fallback(reason:)
    text = @note.body.to_s.downcase
    intent =
      if @note.urgency.to_s == "crisis" then "pain_crisis"
      elsif text.match?(/\b(pain|hurt|moan|gasp|choking|severe)\b/)                     then "pain_crisis"
      elsif text.match?(/\b(breath|breathing|can['t]*\s*breathe|dyspnea|air hunger)\b/) then "dyspnea"
      elsif text.match?(/\b(refill|out of|running low|need more|resupply)\b/)           then "med_refill"
      elsif text.match?(/\b(chaplain|pray|god|faith|afraid|dying|coping|spiritual)\b/)  then "spiritual"
      elsif text.match?(/\b(bed|oxygen|walker|wheelchair|delivery|equipment|dme)\b/)    then "logistics"
      elsif text.match?(/\b(when|where|nurse|visit|schedule|eta|coming)\b/)             then "status_question"
      else "other"
      end

    reply =
      case intent
      when "pain_crisis"
        rn = @patient.assigned_rn&.full_name&.split&.first || "your nurse"
        "I've alerted #{rn} and the MD. Someone will respond within the next few minutes. If this becomes life-threatening, please call 911. We are not emergency services."
      when "dyspnea"
        "Reaching your nurse now. Help him sit upright and loosen anything around his chest while you wait. If he turns blue or stops breathing, call 911."
      when "med_refill"
        "Pinged pharmacy and your nurse. Expect a call within the hour to confirm the refill."
      when "spiritual"
        "Our chaplain and social worker team will reach out today."
      when "status_question"
        "Passed your question to your nurse. They'll reply shortly."
      when "logistics"
        "Notified our DME coordinator. You'll hear back within the next few hours."
      else
        "I've recorded your message and let the team know. Someone will follow up."
      end

    {
      intent:    intent,
      urgency:   @note.urgency.presence || "normal",
      reasoning: "LLMs unavailable (#{reason}). Regex fallback used.",
      reply:     reply,
      source:    "fallback:regex"
    }
  end
end
