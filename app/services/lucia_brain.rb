# Lucia's brain. Routes a family message through an ordered chain of providers
# until one responds: Anthropic Claude, then OpenAI, then a regex fallback.
#
# Contract: always returns a hash with these five keys (never raises).
#   { intent:, urgency:, reasoning:, reply:, source: }
#
# The triager doesn't know or care which provider answered. The `source` field
# records it for audit (e.g. "claude:claude-sonnet-4-6", "openai:gpt-4o",
# "fallback:regex") and flows into agent_session_id on every downstream write.

require "net/http"
require "json"

class LuciaBrain
  SOUL_PATH = File.expand_path("~/.openclaw/agents/admission_coordinator/SOUL.md")

  # Claude primary config
  CLAUDE_URL     = "https://api.anthropic.com/v1/messages"
  CLAUDE_VERSION = "2023-06-01"
  CLAUDE_MODEL   = ENV.fetch("HOSALIVIO_LUCIA_MODEL", "claude-sonnet-4-6")

  # OpenAI fallback config
  OPENAI_URL   = "https://api.openai.com/v1/chat/completions"
  OPENAI_MODEL = ENV.fetch("HOSALIVIO_LUCIA_OPENAI_MODEL", "gpt-4o")

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
        Rails.logger.warn("[LuciaBrain:#{provider}] #{e.class}: #{e.message}")
      end
    end
    fallback(reason: attempts.empty? ? "no_providers_configured" : attempts.join(","))
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
      "You are Lucia, an experienced hospice admissions coordinator. Warm, specific, unhurried."
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

  # Regex fallback. Same return shape so LuciaTriager doesn't know the difference.
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
