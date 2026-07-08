# Generalized agent cognition.
#
# One class. Any role. Composes the system prompt from three layers:
#   1. Universal role archetype   — SOUL.md under ~/.openclaw/agents/<role>/
#   2. Agency persona             — agency.agent_personas[role] (JSONB)
#   3. Agency-specific overrides  — agency.agent_overrides[role] (JSONB or string)
# plus runtime context (patient, event trigger).
#
# Returns (never raises):
#   { action:, params:, reply:, reasoning:, source: }
#
# Same Claude → OpenAI → no_action fallback chain as HosalivioBrain. If the role's
# SOUL.md is still the stock OpenClaw template, short-circuits with no_action
# so handoffs to unconfigured agents stay quiet instead of emitting garbage.

require "net/http"
require "json"

class AgentBrain
  SOUL_DIR = File.expand_path("~/.openclaw/agents")

  # Short role keys (used across the Rails side) → OpenClaw agent directories.
  ROLE_DIRS = {
    "admissions"    => "admission_coordinator",
    "rn"            => "registered_nurse",
    "lpn"           => "licensed_practical_nurse",
    "md"            => "medical_director",
    "don"           => "director_of_nurse",
    "dme"           => "dme_coordinator",
    "pharmacy"      => "pharmacy_coordinator",
    "insurance"     => "insurance_coordinator",
    "billing"       => "billing",
    "chaplain"      => "chaplain",
    "social_worker" => "social_worker",
    "aide"          => "aides"
  }.freeze

  # Output-schema vocabulary. Triager maps each to a concrete DB write.
  ACTIONS = %w[
    write_note write_visit write_med_order write_pharm_delivery
    write_dme_order handoff_to broadcast_reply no_action
  ].freeze

  URGENCIES = %w[crisis urgent normal].freeze

  # Claude config (primary)
  CLAUDE_URL     = "https://api.anthropic.com/v1/messages"
  CLAUDE_VERSION = "2023-06-01"
  CLAUDE_MODEL   = ENV.fetch("HOSALIVIO_AGENT_MODEL", ENV.fetch("HOSALIVIO_LUCIA_MODEL", "claude-sonnet-4-6"))

  # OpenAI config (fallback)
  OPENAI_URL   = "https://api.openai.com/v1/chat/completions"
  OPENAI_MODEL = ENV.fetch("HOSALIVIO_AGENT_OPENAI_MODEL", ENV.fetch("HOSALIVIO_LUCIA_OPENAI_MODEL", "gpt-4o"))

  # OpenRouter (OpenAI-compatible) — optional fallback provider, e.g. GLM.
  # Set OPENROUTER_API_KEY to enable; OPENROUTER_MODEL to the exact slug.
  OPENROUTER_URL   = "https://openrouter.ai/api/v1/chat/completions"
  OPENROUTER_MODEL = ENV.fetch("OPENROUTER_MODEL", "z-ai/glm-5.2")

  PROVIDER_CHAIN = %i[claude openai openrouter].freeze

  # Cap handoff chain depth so RN→MD→RN loops can't runaway.
  MAX_DEPTH = 3

  # Roles that produce clinical narrative (chart-bound text). These get the
  # documentation discipline block appended to their system prompt. Roles that
  # produce structured records (pharm_delivery, dme_order, insurance note,
  # billing claim) are skipped to avoid prompt bloat without protection value.
  ROLES_REQUIRING_DOCUMENTATION_DISCIPLINE = %w[
    admissions rn lpn md aide social_worker chaplain
  ].freeze

  # Universal documentation hygiene. Non-negotiable. Appended to the system
  # prompt for narrative-producing roles, above any agency overrides, so
  # partners can strengthen but not weaken it.
  DOCUMENTATION_DISCIPLINE = <<~RULES
    === CLINICAL DOCUMENTATION RULES (NON-NEGOTIABLE) ===

    These rules govern chart-bound outputs: the `body` field of write_note
    and the `narrative` field of write_visit.

    These rules do NOT govern broadcast_reply content, which is family-facing
    and must stay in plain warm English. Keep the two voices separate: charts
    are audit-proof clinical prose; family replies are human prose.

    FILTERING (what belongs in the chart)
    - Include only clinically relevant hospice information.
    - Drop unrelated dialogue: politics, sports, weather, movies, gossip,
      unrelated personal stories.
    - Drop spiritual or emotional discussion unless it directly indicates
      decline (anxiety, agitation, terminal restlessness).
    - Drop greetings, introductions, rapport-building, small talk.
    - Drop future plans unless they signal decline ("can't walk to church
      anymore" stays; "planning a vacation next month" goes).
    - Drop income, finances, church attendance, hobbies unless directly linked
      to ADL capacity or caregiver burden.
    - If a symptom is mentioned only casually or figuratively, do not
      document it as a clinical finding.
    - If weight loss or appetite change is vague, do not estimate values.

    GROUNDING (no invented data)
    - If the context does not explicitly contain a piece of information,
      leave the field empty or omit it. Do not infer. Do not guess.
      Do not fill with generic statements.
    - NEVER assume: weight loss amount, ADL level, cognitive orientation,
      diagnosis, prognosis, or trajectory.
    - Every clinical claim in your chart output must trace to something in
      the context you were given. If it can't be traced, don't write it.

    LANGUAGE (Medicare-compliant, audit-proof)
    Prefer audit-survivable phrasing:
      - "Patient requires increased assistance with..."
      - "Patient demonstrates progressive decline in..."
      - "Caregiver reports worsening..."
      - "Patient is no longer able to..."
      - "Functional status has deteriorated over..."
      - "Symptoms are consistent with terminal disease progression."

    Avoid vague or hedging terms in chart text:
      "doing okay", "seems fine", "probably", "might", "appears to".
      Be definite or be silent.

    AUDIT AWARENESS
    Assume every chart note you write will be read in an ADR, TPE, or UPIC
    audit and must independently support hospice eligibility. A note that
    says less but is concretely sourced survives audit. A note that says
    more but drifts from the transcript fails.
  RULES

  # Bedside roles that staff Continuous Care shifts: the visiting RN, the LPN
  # (Support Nurse), and the CNA (Care Assistant/aide). They get the CC
  # protocol appended so the role AI follows it whenever the patient is on CC.
  CONTINUOUS_CARE_ROLES = %w[rn lpn aide].freeze

  # Continuous Care protocol. Conditional ("when this patient is on CC") so it
  # never imposes q2h charting on routine visits. Shared rules for all CC
  # staff; role-specific duties are appended per role (see continuous_care_block).
  CONTINUOUS_CARE_PROTOCOL = <<~RULES
    === CONTINUOUS CARE (CC) PROTOCOL — applies WHEN this patient is on Continuous Care ===

    Continuous Care is the Medicare level of care that supplements nursing in
    the patient's home during a crisis (e.g. uncontrolled pain, respiratory
    distress). Everything you chart on CC must JUSTIFY why the patient is on CC.

    DOCUMENTATION (every CC chart entry)
    - PIE format: Problem (the symptom/reason the patient is on CC),
      Intervention (the action you took), Evaluation (how the patient / family
      responded).
    - Make an entry at least every 2 hours, in MILITARY TIME (e.g. 1400, 2100).
    - Tie every entry to the CC reason. Paint a clear picture of the patient
      and family and the care you gave, including emotional support.
    - Note that appropriate PPE was used for the shift; sign with your name and
      credentials and include the patient's team number.
    - Ground every statement in what actually happened — never invent vitals,
      intake, or findings.

    CARE EXPECTATIONS
    - Keep the patient clean, dry, and repositioned every 2 hours and as needed
      for comfort. Offer fluids/food if able (eyes closed does not mean asleep —
      still offer, and chart accepted or refused).
    - If the family asks that the patient not be moved or bathed, HONOR it and
      chart that.

    ESCALATION & SAFETY (critical)
    - On ANY change in condition (moaning, increased anxiety, difficulty
      breathing, etc.): inform the caregiver, notify the team immediately
      (use handoff_to), and chart the problem plus who you notified.
    - NEVER advise calling 911. If the patient dies, do NOT call 911 — the team
      must be notified immediately. Do not tell a family to call 911.
  RULES

  CONTINUOUS_CARE_BY_ROLE = {
    "rn"   => "ROLE — VISIT RN: You make the daily CC visit and provide clinical " \
              "oversight. Give and receive a clear shift report. Confirm the CC " \
              "reason is documented and the q2h PIE entries justify continued CC.",
    "lpn"  => "ROLE — LPN (Support Nurse): Perform a head-to-toe assessment with " \
              "vitals each shift and chart them. You administer medications and keep " \
              "the MAR updated; chart meds given.",
    "aide" => "ROLE — CNA (Care Assistant): Describe the patient in detail and chart " \
              "it. Provide personal care — bathe, dress, keep clean and dry, " \
              "reposition every 2 hours, offer fluids/food. You MAY NOT give " \
              "medications; if meds are needed, notify the LPN or RN."
  }.freeze

  class << self
    def call(role:, agency:, event: nil, context: {}, depth: 1)
      new(role:, agency:, event:, context:, depth:).call
    end

    # Debug / test helper. Returns the composed system prompt text that would
    # be sent to the LLM for a given role + agency. Does NOT make an API call,
    # does NOT spend tokens. Useful for smoke tests of prompt composition.
    def preview_system_prompt(role:, agency:)
      inst = new(role: role, agency: agency)
      [ inst.send(:soul_md),
       inst.send(:persona_block),
       inst.send(:documentation_discipline_block),
       inst.send(:continuous_care_block),
       inst.send(:overrides_block),
       inst.send(:instruction_block) ].reject { |s| s.to_s.strip.empty? }.join("\n\n---\n\n")
    end

    def provider_enabled?(provider)
      case provider
      when :claude     then valid_key?(ENV["ANTHROPIC_API_KEY"])
      when :openai     then valid_key?(ENV["OPENAI_API_KEY"])
      when :openrouter then valid_key?(ENV["OPENROUTER_API_KEY"])
      end
    end

    private

    def valid_key?(k)
      k = k.to_s.strip
      !k.empty? && !k.end_with?("...")
    end
  end

  def initialize(role:, agency:, event: nil, context: {}, depth: 1)
    @role    = role.to_s
    @agency  = agency
    @event   = event
    @context = context || {}
    @depth   = depth.to_i
  end

  def call
    return no_action("depth_cap") if @depth > MAX_DEPTH
    return no_action("soul_not_configured") unless soul_configured?

    attempts = []
    PROVIDER_CHAIN.each do |provider|
      next unless self.class.provider_enabled?(provider)
      begin
        return sanitize(parse(request(provider)), "#{provider}:#{model_for(provider)}")
      rescue => e
        attempts << "#{provider}=#{e.class}"
        Rails.logger.warn("[AgentBrain:#{@role}:#{provider}] #{e.class}: #{e.message}")
      end
    end
    no_action("providers_failed:#{attempts.join(',')}")
  end

  # ──────────────────────────────────────────────────────────────────────

  private

  # Signatures unique to the unfilled OpenClaw template files. If any of these
  # appear, the role hasn't been written for hospice yet.
  STOCK_SIGNATURES = [
    "You're not a chatbot. You're becoming someone",
    "Fill this in during your first conversation",
    "This file is yours to evolve",
    "Pick something you like"
  ].freeze

  def soul_configured?
    content = soul_md.to_s
    return false if content.length < 400
    STOCK_SIGNATURES.each { |sig| return false if content.include?(sig) }
    true
  end

  def no_action(reason)
    {
      action:    "no_action",
      params:    {},
      reply:     nil,
      reasoning: "Stood down (#{reason}).",
      source:    "brain:skip"
    }
  end

  def sanitize(parsed, source)
    action = ACTIONS.include?(parsed[:action]) ? parsed[:action] : "no_action"
    {
      action:    action,
      params:    (parsed[:params].is_a?(Hash) ? parsed[:params] : {}),
      reply:     parsed[:reply].to_s.strip.presence,
      reasoning: parsed[:reasoning].to_s.strip.presence || "(no reasoning provided)",
      source:    source
    }
  end

  def parse(text)
    stripped = text.to_s.sub(/\A```(?:json)?\s*/m, "").sub(/\s*```\z/m, "").strip
    JSON.parse(stripped).transform_keys(&:to_sym)
  end

  # ── LLM calls ─────────────────────────────────────────────────────────

  def request(provider)
    case provider
    when :claude then request_claude
    else              request_oai(provider)   # :openai / :openrouter (OpenAI-compatible)
    end
  end

  def model_for(provider)
    case provider
    when :claude     then CLAUDE_MODEL
    when :openrouter then OPENROUTER_MODEL
    else                  OPENAI_MODEL
    end
  end

  def request_claude
    uri = URI(CLAUDE_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]      = "application/json"
    req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
    req["anthropic-version"] = CLAUDE_VERSION
    req.body = {
      model:      CLAUDE_MODEL,
      max_tokens: 800,
      system: [
        { type: "text", text: soul_md,                 cache_control: { type: "ephemeral" } },
        { type: "text", text: persona_block },
        # Non-negotiable documentation discipline, non-cacheable on purpose so
        # any tightening of CMS rules takes effect on the next deploy.
        { type: "text", text: documentation_discipline_block },
        { type: "text", text: continuous_care_block },
        { type: "text", text: overrides_block },
        { type: "text", text: instruction_block }
      ].reject { |b| b[:text].to_s.strip.empty? },
      messages: [ { role: "user", content: user_prompt } ]
    }.to_json

    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    raise "Anthropic #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("content", 0, "text").to_s
  end

  # OpenAI-compatible request, shared by :openai and :openrouter (GLM). Only the
  # endpoint/key/model differ; OpenRouter omits response_format (not all models
  # support it) and relies on the prompt + lenient JSON parse.
  def request_oai(provider = :openai)
    url, key_env, model =
      case provider
      when :openrouter then [ OPENROUTER_URL, "OPENROUTER_API_KEY", OPENROUTER_MODEL ]
      else                  [ OPENAI_URL, "OPENAI_API_KEY", OPENAI_MODEL ]
      end
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]  = "application/json"
    req["authorization"] = "Bearer #{ENV.fetch(key_env)}"
    if provider == :openrouter
      req["HTTP-Referer"] = ENV.fetch("OPENROUTER_REFERER", "https://hosalivio.com")
      req["X-Title"]      = "HosAlivio"
    end
    system_text = [ soul_md, persona_block, documentation_discipline_block, continuous_care_block, overrides_block, instruction_block ]
                    .reject { |s| s.to_s.strip.empty? }.join("\n\n---\n\n")
    body = {
      model: model, max_tokens: 800,
      messages: [ { role: "system", content: system_text }, { role: "user", content: user_prompt } ]
    }
    body[:response_format] = { type: "json_object" } unless provider == :openrouter
    # GLM-5.2 is a reasoning model; without this it spends the whole token
    # budget on hidden chain-of-thought and returns null content.
    body[:reasoning]       = { enabled: false } if provider == :openrouter
    req.body = body.to_json

    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    raise "#{provider} #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s
  end

  # ── Prompt composition ───────────────────────────────────────────────

  def soul_md
    @soul_md ||= begin
      dir  = ROLE_DIRS[@role] || @role
      path = File.join(SOUL_DIR, dir, "SOUL.md")
      File.exist?(path) ? File.read(path) : ""
    end
  end

  def persona
    @persona ||= (@agency.agent_personas.presence || {})[@role] || {}
  end

  def persona_block
    return "" if persona.empty? && @agency.nil?
    display = persona["display_name"] || @role.humanize
    voice   = persona["voice_notes"]  || "warm, specific, unhurried"
    creds   = persona["credentials"]
    phone   = persona["phone"]
    <<~STR
      === AGENCY-SCOPED IDENTITY ===
      You are #{display}, employed at #{@agency.name} (#{[ @agency.city, @agency.state ].compact.join(", ")}).
      Voice: #{voice}.
      #{"Credentials: #{creds}." if creds}
      #{"Direct line: #{phone}." if phone}
    STR
  end

  def overrides_block
    raw = (@agency.agent_overrides.presence || {})[@role]
    return "" if raw.to_s.strip.empty?
    "=== AGENCY-SPECIFIC RULES ===\n#{raw}"
  end

  # Inject the universal clinical-documentation block for narrative-producing
  # roles only. Roles that only write structured records (pharmacy, dme,
  # insurance, billing) skip this block to keep their prompts tight.
  def documentation_discipline_block
    return "" unless ROLES_REQUIRING_DOCUMENTATION_DISCIPLINE.include?(@role)
    DOCUMENTATION_DISCIPLINE
  end

  # Continuous Care protocol for the bedside CC roles (visit RN / LPN / CNA),
  # with the role's specific duties appended. Empty for other roles.
  def continuous_care_block
    return "" unless CONTINUOUS_CARE_ROLES.include?(@role)
    [ CONTINUOUS_CARE_PROTOCOL, CONTINUOUS_CARE_BY_ROLE[@role] ].compact.join("\n")
  end

  def instruction_block
    <<~STR
      === RESPONSE SCHEMA — this turn only ===
      Output ONLY a JSON object with these keys:

      {
        "action":    one of #{ACTIONS.inspect},
        "params":    { role-appropriate key/value pairs, see action shapes below },
        "reply":     optional short message (string or null),
        "reasoning": one-sentence explanation for the audit log
      }

      Action shapes (pick one action per turn):

      write_note          { "patient_id", "body", "urgency": "crisis|urgent|normal", "author_role": "<your role>" }
      write_visit         { "patient_id", "discipline", "visit_type": "routine|admission|recert|face_to_face|discharge|death",
                             "scheduled_at", "started_at", "ended_at", "narrative", "vitals": {}, "pain_score" }
      write_med_order     { "patient_id", "prescribed_by_id", "drug_name", "dose", "route": "po|sl|sc|iv|im|pr|top|neb|other",
                             "frequency", "prn": true|false, "prn_indication", "start_date", "end_date" }
      write_pharm_delivery { "patient_id", "medication_order_id" (optional), "kind": "comfort_kit|refill|new_fill|emergency" }
      write_dme_order     { "patient_id", "equipment_type", "quantity", "vendor" }
      handoff_to          { "target_role": "rn|md|don|dme|pharmacy|insurance|billing|chaplain|social_worker|aide|admissions",
                             "intent", "urgency": "crisis|urgent|normal" }
      broadcast_reply     { "patient_id", "body", "urgency": "normal" }   (posts a family-visible note from YOU)
      no_action           {}                                              (observe; do not write anything)

      Rules you must follow:
      - Use patient_id from the context. Do not fabricate ids.
      - Do not give medical advice unless you are the MD role.
      - If you hand off, be specific about the intent.
      - Urgency "crisis" means the family is in acute distress right now.
      - You get ONE action per turn. Pick the most consequential one.
    STR
  end

  def user_prompt
    patient = @context[:patient] || {}
    meds    = @context[:active_meds] || []
    notes   = @context[:recent_notes] || []
    ev      = @event
    huddle  = @context[:visits_today_by_discipline] || {}

    <<~STR
      === TRIGGER ===
      #{ev ? "Handed to you by #{ev.agent_id} at #{ev.happened_at}." : "Direct invocation."}
      Intent:  #{@context[:intent]   || ev&.change_set&.dig("intent")   || "(unspecified)"}
      Urgency: #{@context[:urgency]  || ev&.change_set&.dig("urgency")  || "normal"}
      Chain depth: #{@depth}/#{MAX_DEPTH}

      === PATIENT IN QUESTION ===
      id:                #{patient[:id]                 || "(none — observe only)"}
      mrn:               #{patient[:mrn]                || "—"}
      name:              #{patient[:full_name]          || "—"}
      age:               #{patient[:age]                || "—"}
      diagnosis:         #{patient[:primary_diagnosis]  || "—"}
      code status:       #{patient[:code_status]        || "—"}
      status:            #{patient[:status]             || "—"}
      assigned RN:       #{patient[:assigned_rn]        || "(unassigned)"}
      assigned MD:       #{patient[:assigned_md]        || "(unassigned)"}

      === ACTIVE MEDS ===
      #{meds.any? ? meds.map { |m| "- #{m}" }.join("\n") : "(none on file)"}

      === RECENT NOTES (newest first, up to 5) ===
      #{notes.any? ? notes.map { |n| "- [#{n[:role]}] #{n[:body]}" }.join("\n") : "(no prior notes)"}

      === TODAY'S HUDDLE AT THIS PATIENT'S HOME ===
      Already scheduled today (visits with this patient, grouped by discipline):
      #{huddle.any? ? huddle.map { |disc, n| "- #{disc}: #{n}" }.join("\n") : "(no other disciplines visiting today)"}
      Huddle rule: if 2+ other disciplines are already on today's calendar at this home, push your visit to tomorrow unless the trigger is crisis.

      === SCHEDULING CONSTRAINTS ===
      - Clinicians cannot be double-booked. A 30-minute windshield buffer is enforced on both sides of every visit.
      - A standard visit consumes 2 hours of calendar (30 min travel + 60 min visit + 30 min travel).
      - If you try to write_visit at a time that conflicts with any existing visit for this clinician including buffer, the database will reject the write.

      === WHAT TO DO NEXT ===
      Based on your role's SOUL and the agency-scoped identity above, decide the single most useful action this turn.
      Remember: return exactly one JSON object matching the schema. No markdown fences.
    STR
  end
end
