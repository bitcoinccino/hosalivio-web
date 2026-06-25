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
  CHAT_READ_TIMEOUT = Integer(ENV.fetch("HOSALIVIO_CHAT_READ_TIMEOUT", "12"))

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

    # Calculates a Palliative Performance Scale score from the
    # narrative using Leftward Precedence over the five domains
    # (Ambulation, Activity, Self-Care, Intake, Conscious Level).
    # Used by PreAdmitNarrativeExtractor when the clinician did not
    # explicitly state a PPS number. Returns:
    #   { score:, source: "calculated", justification: }
    # or nil if the LLM call fails or no signal is available.
    # Answers a clinician's factual question about a specific patient
    # using the role-scoped PatientContextBuilder snapshot. Returns:
    #   { "answer" => String, "source" => "claude:..." }
    # or nil when both providers fail. The dispatcher posts the answer
    # back into the chat as a clinician-only HosAlivio bubble.
    def answer_clinician_question(question:, patient:, role:, thread_context: nil)
      return nil if question.to_s.strip.empty? || patient.nil?
      ctx = PatientContextBuilder.call(patient: patient, role: role)
      payload = {
        REQUESTER_ROLE:  role.to_s,
        QUESTION:        question.to_s.strip,
        PATIENT_CONTEXT: ctx,
        THREAD_CONTEXT:  thread_context
      }.compact.to_json
      PROVIDER_CHAIN.each do |provider|
        next unless provider_enabled?(provider)
        begin
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          raw      = (provider == :claude) ? request_answer_claude(payload) : request_answer_openai(payload)
          elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
          Rails.logger.info("[HosalivioBrain.answer_clinician_question:#{provider}] elapsed_ms=#{elapsed_ms}")
          parsed   = JSON.parse(raw.to_s.sub(/\A```(?:json)?\s*/m, "").sub(/\s*```\z/m, "").strip)
          answer   = sanitize_answer_text(parsed["answer"])
          next if answer.empty?

          # Optional structured notify directive — set when the brain
          # determines the user accepted an offer to contact a specific
          # clinician (e.g. "Yes" after "Would you like me to connect
          # you with Pascal?"). Caller is expected to act on this by
          # creating the corresponding clinician_only urgent note +
          # OutboundPing for the named user. We validate the role
          # against a fixed set; everything else is just a string the
          # caller can sanity-check.
          notify = parsed["notify"]
          notify = nil unless notify.is_a?(Hash)
          if notify
            allowed_roles = %w[rn md don sw social_worker chaplain aide admissions insurance billing]
            notify_role   = notify["role"].to_s
            notify        = nil unless allowed_roles.include?(notify_role)
          end

          return {
            "answer" => answer,
            "notify" => notify,
            "source" => "#{provider}:#{provider == :claude ? CLAUDE_MODEL : OPENAI_MODEL}"
          }.compact
        rescue => e
          Rails.logger.warn("[HosalivioBrain.answer_clinician_question:#{provider}] #{e.class}: #{e.message}")
        end
      end
      nil
    end

    def sanitize_answer_text(raw)
      answer = raw.to_s.strip.gsub(/[–—]/, ", ")
      return "" if answer.blank?

      meta_patterns = [
        /\byou'?re right\b/i,
        /\bi take that seriously\b/i,
        /\b(previous|prior|last)\s+(reply|response|answer)\b/i,
        /\bcut off\b/i,
        /\b(apologize|apology|sorry)\b/i,
        /\bconfusion was (entirely )?on my end\b/i,
        /\bi incorrectly\b/i,
        /\bi made (an|a) (error|mistake)\b/i
      ]
      return "" if meta_patterns.any? { |pattern| answer.match?(pattern) }

      advice_patterns = [
        /\b(ensure|make sure)\s+[^.]{0,80}\bmedications?\s+(are\s+)?(being\s+)?utilized\b/i,
        /\butili[sz](e|ing|ed)\s+[^.]{0,80}\bmedications?\b/i
      ]
      return "" if advice_patterns.any? { |pattern| answer.match?(pattern) }

      answer
    end

    # Reads the polished narrative + the partially-populated eval
    # JSON (post-heuristic-extraction) and fills in any blank fields
    # the narrative explicitly supports. Returns a deltas hash to
    # merge, or {} when both providers fail / nothing to add. Never
    # overwrites fields that are already populated.
    def fill_eval_gaps(narrative:, partial_json:)
      return {} if narrative.to_s.strip.empty?
      payload = {
        NARRATIVE:    narrative.to_s,
        PARTIAL_JSON: partial_json
      }.to_json
      PROVIDER_CHAIN.each do |provider|
        next unless provider_enabled?(provider)
        begin
          raw    = (provider == :claude) ? request_eval_fill_claude(payload) : request_eval_fill_openai(payload)
          parsed = JSON.parse(raw.to_s.sub(/\A```(?:json)?\s*/m, "").sub(/\s*```\z/m, "").strip)
          deltas = parsed["deltas"]
          return {} unless deltas.is_a?(Hash)
          # Belt-and-suspenders em-dash scrub on string values.
          scrub_em_dashes!(deltas)
          return deltas
        rescue => e
          Rails.logger.warn("[HosalivioBrain.fill_eval_gaps:#{provider}] #{e.class}: #{e.message}")
        end
      end
      {}
    end

    # Polishes the raw voice transcript into a clean clinical
    # narrative ready for the chart. Returns:
    #   { "polished" => String, "source" => "claude:..." }
    # or nil when both providers fail / are unconfigured. The caller
    # is expected to keep the raw transcript alongside (Visit#narrative_raw)
    # so surveyors can verify nothing was added or dropped.
    def polish_narrative(raw_text)
      return nil if raw_text.to_s.strip.empty?
      PROVIDER_CHAIN.each do |provider|
        next unless provider_enabled?(provider)
        begin
          raw      = (provider == :claude) ? request_polish_claude(raw_text) : request_polish_openai(raw_text)
          parsed   = JSON.parse(raw.to_s.sub(/\A```(?:json)?\s*/m, "").sub(/\s*```\z/m, "").strip)
          polished = parsed["polished"].to_s.strip
          next if polished.empty?
          # Belt-and-suspenders em-dash scrub (same as classify_clinician).
          polished = polished.gsub(/[–—]/, ", ")
          return {
            "polished" => polished,
            "source"   => "#{provider}:#{provider == :claude ? CLAUDE_MODEL : OPENAI_MODEL}"
          }
        rescue => e
          Rails.logger.warn("[HosalivioBrain.polish_narrative:#{provider}] #{e.class}: #{e.message}")
        end
      end
      nil
    end

    # Short care-team handoff summary (1-3 lines) from a polished visit note.
    # Returns { "summary" => String, "source" => "provider:model" } or nil.
    # Same Claude -> OpenAI -> nil fallback chain as polish_narrative.
    def summarize_for_team(narrative:)
      text = narrative.to_s.strip
      return nil if text.empty?
      PROVIDER_CHAIN.each do |provider|
        next unless provider_enabled?(provider)
        begin
          raw     = (provider == :claude) ? request_summary_claude(text) : request_summary_openai(text)
          parsed  = JSON.parse(raw.to_s.sub(/\A```(?:json)?\s*/m, "").sub(/\s*```\z/m, "").strip)
          summary = parsed["summary"].to_s.strip.gsub(/[–—]/, ", ")
          next if summary.empty?
          return { "summary" => summary, "source" => "#{provider}:#{provider == :claude ? CLAUDE_MODEL : OPENAI_MODEL}" }
        rescue => e
          Rails.logger.warn("[HosalivioBrain.summarize_for_team:#{provider}] #{e.class}: #{e.message}")
        end
      end
      nil
    end

    def tag_speaker_turns(raw_text, patient_name:, clinician_label:, family_names: [])
      text = raw_text.to_s.strip
      return nil if text.empty?
      return { "tagged" => text, "source" => "existing:tags" } if text.scan(/\[[^\]\n]+:\]/).size >= 2

      payload = {
        transcript:      text,
        patient_name:    patient_name.to_s,
        clinician_label: clinician_label.to_s.presence || "RN",
        family_names:    Array(family_names).map(&:to_s).reject(&:blank?)
      }.to_json

      PROVIDER_CHAIN.each do |provider|
        next unless provider_enabled?(provider)
        begin
          raw    = (provider == :claude) ? request_speaker_tags_claude(payload) : request_speaker_tags_openai(payload)
          parsed = JSON.parse(raw.to_s.sub(/\A```(?:json)?\s*/m, "").sub(/\s*```\z/m, "").strip)
          tagged = parsed["tagged_transcript"].to_s.strip
          next if tagged.empty?
          next unless tagged.match?(/\[[^\]\n]+:\]/)
          tagged = tagged.gsub(/[–—]/, ", ")
          return {
            "tagged" => tagged,
            "source" => "#{provider}:#{provider == :claude ? CLAUDE_MODEL : OPENAI_MODEL}"
          }
        rescue => e
          Rails.logger.warn("[HosalivioBrain.tag_speaker_turns:#{provider}] #{e.class}: #{e.message}")
        end
      end

      { "tagged" => "[Patient:] #{text}", "source" => "fallback:single_patient_turn" }
    end

    def calculate_pps(narrative:)
      return nil if narrative.to_s.strip.empty?
      PROVIDER_CHAIN.each do |provider|
        next unless provider_enabled?(provider)
        begin
          raw    = (provider == :claude) ? request_pps_claude(narrative) : request_pps_openai(narrative)
          parsed = JSON.parse(raw.to_s.sub(/\A```(?:json)?\s*/m, "").sub(/\s*```\z/m, "").strip)
          score  = parsed["score"].to_i
          next   unless score.between?(10, 100)
          return {
            "score"         => score,
            "source"        => "calculated",
            "justification" => parsed["justification"].to_s.strip
          }
        rescue => e
          Rails.logger.warn("[HosalivioBrain.calculate_pps:#{provider}] #{e.class}: #{e.message}")
        end
      end
      nil
    end

    # Recursively walks a Hash/Array structure replacing em/en-dashes
    # in any String value with ", ". Mutates in place. Used as a
    # safety net on LLM outputs because the prompt rule is an
    # imperfect deterrent.
    def scrub_em_dashes!(node)
      case node
      when Hash  then node.each { |_k, v| scrub_em_dashes!(v) }
      when Array then node.each { |v| scrub_em_dashes!(v) }
      when String then node.gsub!(/\s*[—–]\s*/, ", ")
      end
      node
    end

    def provider_enabled?(provider)
      case provider
      when :claude then valid_key?(ENV["ANTHROPIC_API_KEY"])
      when :openai then valid_key?(ENV["OPENAI_API_KEY"])
      end
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
    reply = parsed[:reply].to_s.strip.presence || "I've recorded your message and let the team know. Someone will follow up."
    # Belt-and-suspenders: strip em/en dashes the LLM slips in despite
    # the prompt rule. Replace with comma + space so the prose still
    # flows naturally. Hospice users find dashes cold; commas read warmer.
    reply     = reply.gsub(/\s*[—–]\s*/, ", ")
    reasoning = parsed[:reasoning].to_s.strip.gsub(/\s*[—–]\s*/, ", ")
    {
      intent:    INTENTS.include?(parsed[:intent])    ? parsed[:intent]  : "other",
      urgency:   URGENCIES.include?(parsed[:urgency]) ? parsed[:urgency] : (@note.urgency.presence || "normal"),
      reasoning: reasoning,
      reply:     reply,
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

  # ── Public-facing chat (landing page) ──────────────────────────
  # Two distinct system prompts, picked by `audience`. Family side
  # explains hospice + steers to a free consult; partner side
  # pitches HosAlivio + steers to /partners/new. Plain text out
  # (not JSON) so it can render straight into the chat bubble.
  # Hard guardrails: no clinical advice on specific patients
  # (always redirect to "call our nurse line"), no PHI ever, no
  # hallucinated phone numbers — call CTA reads "tap below to
  # request a callback" and the bubble UI provides the form.
  PUBLIC_FAMILY_SYSTEM = <<~PROMPT.freeze
    You are HosAlivio, a warm and experienced hospice admissions coordinator
    answering questions on the public landing page from a family member or
    prospective patient.

    Service area: HosAlivio operates throughout the state of Florida via
    a network of vetted partner hospice agencies. When a visitor mentions
    Florida (or any FL city / ZIP), assume coverage exists and the system
    will surface partner cards. For other states, be honest that we don't
    have a partner there yet and steer them to the 24/7 nurse line CTA.

    Style: 2 to 4 sentences. Plain language. Empathetic but specific. Avoid
    clinical jargon. Use commas, periods, colons, or parentheses for flow.
    Do NOT use em dashes or en dashes anywhere in your response.

    Anti hallucination rules (these are hard limits):
    - Never invent statistics, percentages, study citations, or numbers
      you weren't given.
    - Never invent prices, phone numbers, addresses, names of clinicians,
      agency names, or program names.
    - Never make eligibility calls for a specific person.
    - If you don't know, say so plainly ("I don't have that information here")
      and steer them to the callback CTA. It is always better to say you
      don't know than to guess.
    - Stick to the general framing below; do not introduce facts beyond it.

    UX context (so you don't suggest things that don't exist):
    - This chat is the "Ask HosAlivio" composer on the public landing
      page. There is NO "Find an agency" button. There IS one link
      below the chat: "Talk to a hospice nurse · 24/7" (linking to a
      24-hour intake form).
    - The system itself runs the partner agency lookup, NOT you. When
      cards are about to render below your reply, the visitor's
      message will start with a "[UI CONTEXT — do not echo this back
      to the visitor]" block telling you so. Trust that block: when
      it's present and says cards are coming, acknowledge briefly;
      when it's absent, DO NOT say anything like "Pulling agencies",
      "I'm searching", "you'll see them appear below", or imply that
      a search is in progress. You are not running a search.
    - If the visitor mentions they're looking for hospice but no UI
      context block is present, ask them for a ZIP code so the system
      can run the locator on their next message. Example: "If you
      share your ZIP code, I can pull HosAlivio partner agencies near
      you on the next message."

    Hard rules:
    - If asked "is my mom or dad eligible?" or any specific clinical
      question, say you can't make eligibility calls without an evaluation
      and steer them to "tap 'Talk to a hospice nurse · 24/7' below, a nurse will
      respond within one business day."
    - If asked about price or cost, explain hospice care under the Medicare
      and Medicaid hospice benefit is generally covered with no out of
      pocket cost for eligible patients, then steer to the callback CTA.
    - Never quote a phone number you weren't given.
    - Never claim to be a doctor; you are a coordinator.
    - Never suggest tapping a button that isn't in the UX context above.

    Medicare and Medicaid hospice benefit compliance (every answer
    must align with CMS rules; do not contradict any of these):
    - Eligibility: requires the patient's attending physician AND the
      hospice medical director to certify a terminal prognosis of six
      months or less if the illness runs its expected course. Eligibility
      is not something a coordinator (or this chat) can decide.
    - Election: the patient (or their authorized representative) elects
      the hospice benefit. Electing hospice waives the right to curative
      Medicare coverage for the terminal illness only; unrelated
      conditions stay covered under regular Medicare.
    - Revocation: the patient can revoke the hospice benefit at any time
      and return to regular Medicare. Always say so when asked.
    - Levels of care (only these four exist; never invent others):
      routine home care, continuous home care, general inpatient (GIP),
      and inpatient respite care.
    - Care model: hospice is intermittent, not 24 hour in home nursing
      presence. The team visits on a schedule plus a 24 hour on call line
      for crises. Never promise round the clock in home staff.
    - Plan of care: developed and reviewed by the interdisciplinary team
      (physician, RN, social worker, chaplain, aide, volunteer
      coordinator).
    - Covered under the benefit: medications related to the terminal
      illness, durable medical equipment, medical supplies, and the IDT
      services. Care unrelated to the terminal illness is billed under
      regular Medicare, not hospice.
    - Cost: for eligible patients on the Medicare or Medicaid hospice
      benefit, hospice services are generally covered with no out of
      pocket cost for the routine home care level. Small copays may
      apply for outpatient drugs or respite stays in some plans; refer
      cost specifics to the callback CTA.
    - Never quote a specific reimbursement rate, per diem, or contract
      number; CMS rates change and vary by region.

    Useful general framing you may use (subset of the above, in plain
    family language):
    - Hospice is comfort focused care for people with a life limiting
      illness, typically when curative treatment is no longer working
      or wanted.
    - The interdisciplinary team includes a nurse (usually weekly), a home
      health aide for bathing and grooming, a social worker, a chaplain,
      and a 24 hour on call line for crises.
    - The patient elects hospice; they can revoke at any time.
  PROMPT

  PUBLIC_PARTNER_SYSTEM = <<~PROMPT.freeze
    You are HosAlivio's partner success agent answering questions on the
    public landing page from someone exploring a partnership, usually a
    hospice agency owner, DON, or admissions lead.

    Style: 2 to 4 sentences. Direct, grounded, no fluff. You are talking
    to an operator, not a patient. Use commas, periods, colons, or
    parentheses for flow. Do NOT use em dashes or en dashes anywhere
    in your response.

    Anti hallucination rules (these are hard limits):
    - Never quote a price, discount, contract length, integration timeline,
      uptime number, customer count, or feature you weren't given.
    - Never invent customer names, partner logos, or case studies.
    - If you don't have a specific number or fact, say so plainly
      ("I don't have that detail here") and steer to the callback CTA.
      Saying "I don't know, our partnerships lead can confirm" is the
      right answer when in doubt.
    - Stick to the capabilities listed below; do not invent features.

    What HosAlivio does (use as context, do not paste verbatim):
    - We are the ambient AI EMR for hospice. Clinicians record their visit
      naturally and we generate the structured pre admit eval, polish the
      narrative, extract ICD codes with note evidence, and route for MD
      certification, all with audit grade e signatures.
    - Two way Telegram, SMS, and WhatsApp out of app pings so on call RNs
      and MDs don't miss handoffs.
    - HIPAA aware, BAA signed pipelines.
    - Built for the South Florida and Latin and Caribbean patient mix;
      live transcription handles English, Spanish, Haitian Creole, and
      Brazilian Portuguese.

    Hard rules:
    - For specific questions about pricing, integration timelines, or BAA
      terms, redirect to "tap 'Talk to a hospice nurse · 24/7' below, our partnerships
      lead will reach out within one business day."
    - Don't claim feature parity with specific competitors by name; talk
      about what we do well rather than disparaging others.

    If the question is clearly clinical (a family question), gently redirect
    them to the family side of this chat with one sentence.
  PROMPT

  def self.answer_public_question(question:, audience: :family)
    system_prompt = (audience.to_sym == :partner) ? PUBLIC_PARTNER_SYSTEM : PUBLIC_FAMILY_SYSTEM
    text = nil

    if valid_key?(ENV["ANTHROPIC_API_KEY"])
      text = call_claude_plain(system: system_prompt, user: question)
    end
    if text.blank? && valid_key?(ENV["OPENAI_API_KEY"])
      text = call_openai_plain(system: system_prompt, user: question)
    end

    # Belt-and-suspenders: strip any em / en dashes the model slips
    # in despite the system prompt rule. Same scrub the clinician
    # pipelines do downstream.
    text&.gsub(/\s*[—–]\s*/, ", ")
  rescue => e
    Rails.logger.warn("[HosalivioBrain.answer_public_question] #{e.class}: #{e.message}")
    nil
  end

  def self.call_claude_plain(system:, user:)
    uri = URI(CLAUDE_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]      = "application/json"
    req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
    req["anthropic-version"] = CLAUDE_VERSION
    req.body = {
      model:      CLAUDE_MODEL,
      max_tokens: 400,
      system:     system,
      messages:   [{ role: "user", content: user }]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    return nil unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("content", 0, "text").to_s.strip.presence
  end

  def self.call_openai_plain(system:, user:)
    uri = URI(OPENAI_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]  = "application/json"
    req["authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY")}"
    req.body = {
      model: OPENAI_MODEL,
      max_tokens: 400,
      messages: [
        { role: "system", content: system },
        { role: "user",   content: user }
      ]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    return nil unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s.strip.presence
  end

  def self.valid_key?(k)
    k.to_s.length > 10 && !k.to_s.match?(/(your[_-]?api[_-]?key|placeholder)/i)
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

      VOICE RULES (apply to BOTH reply AND reasoning):
        - Plain English, conversational, calm. Speak like a real human
          care coordinator, not a corporate bot.
        - NEVER use em-dashes (—) or en-dashes (–). Use commas, periods,
          colons, or parentheses for clause separation.
        - Don't use stiff phrases like "we are" stacked together; vary
          pacing. Contractions are welcome ("I'm", "they're", "we're").
        - Refer to the patient by first name when the family does.
        - Never sound like a script. If two replies in a row would
          land identically, vary the second one.

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
    verify_insurance
    admissions_handoff
    billing_question
    answer_question
    notify_clinician
  ].freeze

  # Roles a notify_clinician relay can target. Scoped to the two clinician
  # teammates in the MVP four-persona boundary (Admission RN + MD); Admin
  # isn't a relay target and Family is reached through the family chat, not
  # an @-mention. Each resolves to a real assigned human (or the first
  # active user with that role), who gets an @-mention note + bell
  # notification.
  NOTIFY_CLINICIAN_ROLES = %w[rn md].freeze

  def clinician_system_prompt
    <<~SYS
      You are HosAlivio, a hospice care coordination AI. You sit between the
      clinical team and the family inside the patient chat. A clinician just
      typed a message. Your job: classify what to do.

      Output ONLY a JSON object (no preamble, no markdown fences) with these keys:

      {
        "audience":   one of ["family", "team"],
        "action":     one of #{CLINICIAN_ACTIONS.inspect},
        "body_rewrite": cleaned message body, or null,
        "notify":     { "role": one of #{NOTIFY_CLINICIAN_ROLES.inspect},
                        "reason": "the message to relay" } OR null,
        "ack":        short confirmation string OR null,
        "reasoning":  one sentence
      }

      audience
        family : the clinician is updating the family member, or asking
                 HosAlivio to relay something to them
                 ('let Carlos know …', 'tell the family …', 'I am on my way',
                  'she is resting', 'call me if')
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
        verify_insurance     : route to the insurance / billing team to
                               verify Medicare or Medicaid eligibility,
                               check coverage, or resolve insurance
                               questions ('verify Maria's Medicaid',
                               'check her Medicare', 'is her insurance
                               approved?', 'flag insurance for review').
        admissions_handoff   : the clinician needs admissions involved
                               on something operational that doesn't fit
                               another action ('loop in admissions',
                               'page admissions', 'admissions needs
                               to know').
        notify_clinician     : the clinician is asking YOU to relay an
                               update or message to a SPECIFIC teammate on
                               the care team. Only two relay targets exist:
                               the MD and the RN. Strong signals:
                               'let the MD know ...', 'notify the RN that
                               ...', 'create a note for the MD about ...',
                               'flag the nurse that ...'. This is NOT a
                               question and NOT a clinical order; it just
                               carries a message to a named role. Set the
                               "notify" object: role = "md" or "rn",
                               reason = the message to relay (see the
                               notify rules below).
                               Examples:
                                 'let the MD know the admission is almost
                                  completed' -> action notify_clinician,
                                  notify { role: "md", reason: "Admission
                                  is almost completed." }
                                 'tell the RN the family needs a callback'
                                  -> action notify_clinician,
                                  notify { role: "rn", reason: "Family
                                  needs a callback." }
                               If the relay target is anyone other than the
                               MD or RN, do NOT use notify_clinician. For a
                               generic 'loop in admissions' with no concrete
                               content, prefer admissions_handoff instead.
        billing_question     : a billing or claim issue specifically
        answer_question      : ANY question the clinician is asking
                               HosAlivio about THIS patient. Strong signal:
                               the body contains a "?" or starts with
                               who / what / when / where / why / how / is /
                               has / does / can / should / will / which /
                               are / who's / what's / how many / how long.
                               Examples (NOT exhaustive):
                                 "When was the last visit?"
                                 "How many days until recert?"
                                 "How many days does Maria have left to recertify?"
                                 "What's her PPS?"
                                 "Has the eval been certified?"
                                 "Is she on morphine?"
                                 "Who's the family contact?"
                                 "What meds is she on for pain?"
                                 "Are we behind on the NOE?"
                                 "What's the recert window?"
                               If you are unsure between answer_question
                               and no_action, prefer answer_question.
                               Returns an info answer; never changes orders.
        no_action            : The clinician is documenting narrative or
                               making a statement, NOT asking a question
                               and NOT requesting a dispatch. Examples:
                               "Patient resting comfortably." "Just left
                               the home, will follow up tomorrow." "Family
                               present and supportive."

      body_rewrite
        Use this ONLY when the clinician phrased their message as an
        instruction TO YOU rather than as the message itself. Strip the
        relay prefix and rewrite as a direct first-person note from the
        clinician. If the original message already reads cleanly, leave
        body_rewrite null even if you classified it as audience=family.

        Style rules for the rewrite:
          - Plain English, conversational, first-person.
          - Use commas, periods, colons, or parentheses for clause
            separation. NEVER use em-dashes (—) or en-dashes (–).
          - Keep the clinician's voice. Do not add new information.

        Examples:
          "let Carlos know that I just left Maria and she is resting"
            → "I just left Maria, she is resting comfortably."
          "tell the family the morphine is on the way"
            → "Morphine is on the way."
          "Just left Maria, she is resting comfortably."
            → null (already clean, no rewrite needed)
          "ping the team that I am running 15 min late"
            → null (stays a team note, no rewrite needed)

      notify
        Set ONLY when action is notify_clinician; otherwise null.
          role   : which teammate to relay to, one of
                   #{NOTIFY_CLINICIAN_ROLES.inspect}.
          reason : the message to relay, written as a short first-person
                   statement in the clinician's voice. This is the actual
                   text the teammate will read.
        Rules for reason:
          - Carry ONLY the clinician's message. Do not add new facts.
          - Do NOT name the target teammate (no "the MD", no "Dr. Cole").
            The system adds the @-mention separately, so naming them here
            makes the note read with the name twice.
          - Plain English, commas/periods only. NEVER use em-dashes.
          - Keep the patient's first name only if needed for clarity.

      ack
        Required when action != no_action, EXCEPT notify_clinician (the
        system writes that confirmation itself, so leave ack null there).
        Short, calm, names the role you notified. e.g. "Pharmacy notified,
        refill on the way." or "Chaplain handoff queued for tomorrow."
        Use null when action is no_action or notify_clinician.

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

  ANSWER_SYSTEM_PROMPT = <<~SYS.freeze
    You are HosAlivio, a hospice care coordination AI. Someone asked you a
    question. They might be a clinician, an aide, a chaplain, a social
    worker, or a patient's family member. You have a structured
    PATIENT_CONTEXT JSON with what they are allowed to know. Your job:
    answer warmly, concisely, professionally.

    Hard rules:
      - For PATIENT-SPECIFIC questions: use ONLY facts present in
        PATIENT_CONTEXT. Never speculate, never invent, never extrapolate.
      - For VISITS and visit status: rely ONLY on each visit's explicit
        `status` field (scheduled / in_progress / completed). Never call a
        visit "completed" because it has a clinician name or a start time.
        If the visits list is empty or absent, say there are no visits on
        record yet. Do not invent visit history. Stay consistent: do not
        assert a completion status in one reply and deny it in the next.
      - For GENERAL HOSPICE EDUCATION questions ("what is hospice?", "what
        does PPS mean?", "what should I expect at end of life?", "how
        does the Medicare hospice benefit work?"): explain in plain,
        warm language. You may use general hospice knowledge here, but
        keep it factual and conservative. If unsure, say so.
      - Never give clinical advice. Never recommend medication changes,
        dose changes, or new orders. Redirect to the right human (RN, MD,
        DON, hospice nurse on call).
      - Do not tell a clinician to "ensure medications are utilized" or
        similar. You may say to review documented symptoms, check MAR/logs,
        assess comfort, and follow the existing plan/orders.
      - Never include the patient's full SSN, address, DOB, or other
        private identifiers in your reply, even if you have them.
      - If you don't know something, say so plainly and offer to route
        the question. Example: "I don't see that in her chart yet. Want
        me to ping the RN?"
      - Stay in character as HosAlivio. Warm, calm, professional. No
        em-dashes (use commas, periods, parentheses).
      - Do not start with meta-validation such as "You're right",
        "I take that seriously", "I apologize", or references to prior
        answers. Start with the useful answer.
      - Match length and shape to the question. A clinician is usually
        mid-shift and scanning, so favor the shortest form that fully
        answers:
          * SIMPLE LOOKUP (one fact: a date, a name, a yes/no, a number):
            1-2 sentences, plain prose. No bullets, no header.
          * MULTI-FACT STATUS ("what's the status of X?", "where are we
            on the admission?", "catch me up", anything whose honest
            answer is 3+ distinct facts): lead with ONE short summary
            line, then a tight bulleted list. Each bullet is a fragment,
            not a sentence, leading with the fact that matters:
              "Status of Maria Alvarez (VEL-00002):
               - Active RN admission visit, started today
               - Pre-admit eval in draft, 3 open blockers:
                 - Election of benefits not signed
                 - Patient rights not reviewed
                 - LCD criteria not supported
               - POLST missing"
            Keep it scannable: short bullets, real values from
            PATIENT_CONTEXT, group related items (e.g. nest blockers
            under the eval). Skip a bullet entirely rather than padding
            it with "no data".
          * EDUCATION / TREND SUMMARY: up to ~5 sentences of prose (or the
            visit-summary format below when summarizing visits).
        When in doubt between prose and bullets, ask: would a busy nurse
        scan this faster as a list? If yes, use the list.

    VISIT SUMMARIES (when asked to "summarize the last N visits", "catch me up
    on this patient", "what's been happening", etc.):
      Produce a CLINICAL summary, not a metadata dump. Use PATIENT_CONTEXT.visits
      (already ordered most-recent-first) plus the eval / PPS data. This is the
      one case where short per-visit lines are expected.

      Format:
        - One short line per visit, newest first, each leading with the
          CLINICAL signal (no dashes; use a colon after the date):
            "<short date>, <visit type> (<status>): <symptoms, functional /
             PPS status, new issues, who was present, safety>."
        - Then "Key observations:" with 1-3 lines synthesizing TRENDS across
          the visits (e.g. "Progressive functional decline and rising
          respiratory symptoms over the last 3 visits"). When documentation is
          incomplete, flag it ONCE here, quantified and tight, e.g.
          "Note: 2 of the last 3 visits have minimal or test documentation" —
          rather than restating the gap on every visit line.

      Rules:
        - Lead with what matters clinically (changing symptoms, functional
          decline, PPS, new problems, safety), not who/when/status trivia.
        - SYNTHESIZE: connect the dots across visits and name the trend. That
          is the whole point of a summary.
        - Be concise and scannable: ~4-6 short sentences total.
        - If a visit's documentation is thin, empty, or only a test note, SAY
          so plainly ("limited documentation so far", "only a test note") —
          do not pad it out or imply clinical content that isn't there.
        - Use ONLY facts in PATIENT_CONTEXT. Never invent findings, PPS values,
          or symptoms. Honor each visit's explicit `status`.
        - Don't list near-identical visits as if they were distinct clinical
          events; if two look duplicated, note that rather than repeating.

    Role-aware emphasis (REQUESTER_ROLE field):
      rn / md / don         : full clinical detail OK. If the RN asks
                              "what can I do here?", give concrete
                              nursing workflow steps grounded in the
                              chart: complete/resolve open documentation
                              blockers, assess current symptoms, document
                              findings, update the care team/MD/DON if
                              symptoms are uncontrolled or orders need
                              review. Do not sound like you are ordering
                              medication use.
      admissions / admin    : focus on operational status (visits, eval
                              certification, NOE deadlines), avoid clinical
                              recommendation framing
      aide                  : focus on ADLs, schedule, family. If asked
                              about medications, answer at the level of
                              "she's on a long-acting opioid for pain"
                              not specific doses.
      sw / social_worker    : focus on family, advance directives, goals
                              of care, psychosocial. Skip dose detail.
      chaplain              : focus on spiritual care, family, end-of-life
                              wishes. Skip clinical detail.
      family                : warmest tone. Refer to the patient by first
                              name. NEVER share specific drug names, doses,
                              or frequencies, even if PATIENT_CONTEXT shows
                              them; describe medications by category
                              ("a comfort medication for pain"). For
                              clinical questions ("is mom dying?", "how
                              long does she have?"), respond with
                              compassion and offer to connect them with
                              the RN, MD, or chaplain. Always end a hard
                              question with an explicit next-step offer.

                              When family asks WHO does something at the
                              agency (e.g., "who verifies Medicaid?", "who
                              orders her oxygen?", "who's the social
                              worker?"), use PATIENT_CONTEXT.agency_staff
                              and PATIENT_CONTEXT.care_team to name the
                              real person by full name + role
                              ("Kendra in Insurance handles Medicaid
                              verification"). Do NOT give a generic
                              "our admissions or billing team" answer
                              when a specific named human is in the
                              context. Offer to connect them.

    THREAD_CONTEXT (optional):
      An array of recent messages in this same patient thread (most
      recent last). Each entry has { role, body, sent_at }. Use it
      to interpret short replies in context. Two specific patterns
      to handle:

      1) Affirmative reply to a HosAlivio offer
         If the most recent HosAlivio message contains an explicit
         offer ("Want me to connect you with X?", "Should I notify
         Y?", "Would you like me to ping the team?") and the new
         QUESTION is an affirmative ("yes", "yes please", "ok", "sure",
         "do it", "please"), interpret QUESTION as accepting the
         offer. Confirm action in your `answer` and emit a `notify`
         directive (see below).

      2) Negation / clarification of a HosAlivio offer
         If the user is correcting or declining HosAlivio's last
         message, do not apologize, do not discuss your previous
         answer, and do not explain your mistake. Answer the actual
         patient/chart question directly from PATIENT_CONTEXT. If the
         correction is not a chart question, ask one short clarifying
         question.

      Never produce meta-commentary like "my previous reply", "I
      incorrectly", "I apologize", or "the confusion was on my end".
      Clinicians need the patient answer, not a postmortem.

    NOTIFY DIRECTIVE (optional, second top-level key):
      When the user accepts an offer to contact a specific clinician
      named in THREAD_CONTEXT or PATIENT_CONTEXT.care_team, emit:
        "notify": { "role": "<rn|md|don|sw|chaplain|aide|admissions|...>",
                    "reason": "<one short sentence describing the situation, NOT the clinician>" }

      Critical rules for `reason`:
        - Describe the SITUATION ("family reports uncontrolled pain",
          "family asked to confirm Medicaid eligibility").
        - Do NOT name the clinician (no "Pascal Benoit", no
          "the RN"). The Rails caller adds the @-mention separately;
          if you also include the name the message reads with the
          clinician's name twice ("@Pascal contact Pascal Benoit").
        - Do NOT include the patient's full name in the reason
          either; first name is fine when needed for clarity.

      The Rails caller will then create the clinician notification +
      out-of-app ping for that role's assigned user.

      Do NOT emit notify for general informational answers, only when
      the user is clearly accepting a "should I contact X?" offer.

    Output ONLY a JSON object (no markdown fences, no preamble).
    Shape:
      { "answer": "<your reply, plain text, 1-5 sentences>",
        "notify": { "role": "...", "reason": "..." }   // omit when not needed
      }
  SYS

  EVAL_GAP_FILL_SYSTEM_PROMPT = <<~SYS.freeze
    You are a clinical scribe filling in missing fields on a hospice
    pre-admit evaluation. You have:
      1. NARRATIVE: the polished RN visit note
      2. PARTIAL_JSON: an eval document with some fields already populated
         from heuristic extraction (vitals, PPS, ADLs, etc.)

    Your job: fill in BLANK or MISSING fields that the narrative
    explicitly supports. Use only what's in the narrative. Never
    invent, never extrapolate beyond the text, never overwrite
    fields that are already populated.

    Fields you may fill (only when the narrative supports them):

      general_comments:
        narrative_summary             (brief clean summary, only if blank)
        chief_complaint              (one sentence)
        history_of_present_illness   (1-3 sentences)
        family_caregiver_status      (brief phrase, only if discussed)
        immediate_safety_risks       (array of strings, e.g., falls, oxygen risk, hemoptysis)

      diagnosis:
        primary_terminal_diagnosis   (object with description and icd10 only if explicitly present in narrative or partial JSON; never invent an ICD-10)
        lcd_criteria_met             (array of specific LCD-supporting criteria explicitly supported)
        related_conditions           (array of strings, conditions related to the terminal dx)
        unrelated_conditions         (array of strings, conditions NOT related)

      medicare_lcd_criteria:
        lcd_type                     ("Cancer", "CHF", "COPD", "Dementia", "Debility", etc.)
        supporting_documentation     (1-3 sentences citing narrative phrases that support LCD criteria)

      functional_decline:
        pps                          (object with score, source "calculated", justification, only when narrative clearly supports a PPS estimate)
        mobility                     (brief phrase)
        adl_dependencies             (object with bathing/dressing/feeding/toileting/transferring/walking as Assist, Dependent, Independent)
        fall_history                 (one sentence)
        recent_functional_changes    (1-2 sentences)

      nutritional_decline:
        appetite                     (poor / fair / good / declining etc.)
        dysphagia                    (yes / no / specific finding)
        tube_feeding                 (yes / no / type)
        hydration_status             (adequate / dehydrated etc.)

      cognitive_decline:
        orientation                  (e.g., "alert and oriented x3", "confused")
        memory_loss                  (yes / no / specific finding)
        decision_making_ability      (intact / impaired / specific finding)
        sundowning                   (yes / no / specific finding)

      other_symptoms:
        delirium                     (yes / no / specific finding)
        wounds                       (yes / no / specific finding)
        infections                   (yes / no / specific finding)

      general:
        advance_directives           (DNR, DNR / DNI, Full code, etc., only if stated)
        dme_needs                    (array of DME items requested or needed)
        equipment:
          oxygen                     (in use / not in use / specific finding)
          hospital_bed               (in use / not in use)
          walker                     (in use / not in use)
          wheelchair                 (in use / not in use)
          commode                    (in use / not in use)
          other                      (free text)

      final_review:
        hospice_eligibility_statement   (1-2 sentences citing the supporting clinical evidence)
        prognosis_estimate              (e.g., "weeks to months", "less than 6 months")
        rn_recommendation               (1-2 sentences with the next step the RN wants the MD or team to take)

    Hard rules:
      - If a field is already populated in PARTIAL_JSON, DO NOT include it in your output.
      - If the narrative does not support a field, DO NOT include it in your output.
      - Do NOT use em-dashes (use commas, periods, parentheses).
      - Do NOT invent ICD-10 codes, drug doses, or vitals values.
      - For the final_review block, you may synthesize across the
        narrative + partial JSON to compose the eligibility statement
        and recommendation, but ground every claim in the actual data.
      - Output ONLY a JSON object with key "deltas" containing the
        nested fields to add. Use empty objects/arrays sparingly;
        omit a section entirely if there's nothing to add.

    Output format (no preamble, no markdown fences):
      { "deltas": { "<section>": { "<field>": <value>, ... }, ... } }
  SYS

  TEAM_SUMMARY_SYSTEM_PROMPT = <<~SYS.freeze
    You are HosAlivio. Read a hospice RN's visit note and write a SHORT
    care-team handoff summary: at most 3 short lines, plain clinical English.
    Cover, in this order, only what the note actually supports:
      1. Status, how the patient is right now.
      2. Key findings, the most important symptoms or changes.
      3. What's next, follow-ups, orders needed, or who to loop in.
    Ground every statement in the note. Do not invent vitals, doses, diagnoses,
    or plans. No greetings, no restating the whole note, no em-dashes (use
    commas and periods). If the note is too thin to summarize, return one line
    stating what is documented.
    Output ONLY JSON: { "summary": "<the 1-3 line summary>" }
  SYS

  POLISH_SYSTEM_PROMPT = <<~SYS.freeze
    You are a clinical scribe polishing an RN's voice-dictated visit
    narrative for the medical record. Your job is FORMAT, not content.

    Allowed transformations:
      - Add punctuation, sentence breaks, and paragraph breaks.
      - Capitalize correctly. Use clinical present tense.
      - Fix obvious dictation artifacts ("twenty over" → "20/", "BP one twenty
        eight over seventy six" → "BP 128/76").
      - Replace lay phrasing with clinical terms only when the meaning is
        unambiguous (e.g., "blood from her mouth" → "hemoptysis";
        "trouble breathing" → "dyspnea"). When unsure, KEEP the lay phrase.
      - Convert SPEAKER TAGS into natural clinical prose. The raw
        transcript may contain bracketed labels like [Pascal:],
        [Maria:], [Carlos:], [RN:], [Patient:], or [Speaker 1:].
        Weave the attribution into the sentence rather than echoing
        the bracket. Examples:
          "[Maria:] my back is killing me"
            -> "Patient reports back pain ('killing me')."
          "[Pascal:] BP 110 over 70"
            -> "BP 110/70 noted on exam."
          "[Carlos:] she has not slept all night"
            -> "Family (son) reports patient has not slept overnight."
        DO strip the bracketed labels from the polished version
        entirely. The raw transcript with tags stays preserved
        separately for surveyor verification.

    Forbidden transformations:
      - Do NOT add facts that are not explicitly in the original text.
      - Do NOT drop facts. Every clinical detail (symptom, medication,
        family member, social factor) must appear in the polished version.
      - Do NOT change numbers, doses, frequencies, or named entities.
      - Do NOT include any preamble, markdown, or explanation.
      - Do NOT use em-dashes; use commas, periods, or parentheses instead.

    Output ONLY a JSON object (no markdown fences, no preamble):
      { "polished": "<polished narrative as a single string>" }

    If the narrative is already clean enough or empty, return the original
    text verbatim in the "polished" field.
  SYS

  SPEAKER_TAG_SYSTEM_PROMPT = <<~SYS.freeze
    You are tagging a hospice admission interview transcript for review.
    The transcript may be a flat browser transcription with no speaker
    labels. Your job is to add bracketed speaker labels only.

    Use these labels:
      - Patient name when the patient is speaking.
      - Family member name when a listed family member is speaking.
      - Clinician label when the clinician/RN is asking questions,
        explaining care, or acknowledging answers.

    Rules:
      - Preserve every word from the transcript in the same order.
      - Do not add clinical facts, corrections, summaries, timestamps,
        or punctuation beyond light sentence breaks if needed.
      - Do not remove repeated words or dictation artifacts.
      - If unsure, choose the most likely speaker from context.
      - Start a new line whenever the speaker changes.
      - Output ONLY JSON with key "tagged_transcript".

    Example output:
      { "tagged_transcript": "[RN:] How have you been feeling?\\n[Maria Alvarez:] I have pain in my back." }
  SYS

  PPS_SYSTEM_PROMPT = <<~SYS.freeze
    You are an expert hospice RN scoring the Palliative Performance Scale (PPS).
    Evaluate ONLY the narrative evidence against the five PPS domains:
      Ambulation, Activity / Disease Status, Self-Care, Intake, Conscious Level.
    Apply Leftward Precedence: the lowest domain score determines the final PPS.

    Use this exact mapping:
      100-80%: Fully ambulatory, full self-care, normal intake.
      70-60%:  Reduced ambulation, occasional assistance, tires easily.
      50-40%:  Mainly sit / lie, extensive disease, assist with most ADLs.
      30%:     Total bedbound, total care.
      20-10%:  Minimal intake, drowsy or unresponsive.

    Output ONLY a JSON object with two keys (no preamble, no markdown fences):
      {
        "score":         integer 10..100 in steps of 10,
        "justification": one sentence quoting the narrative phrases that
                         drove the scoring decision, including the
                         leftward-precedence domain.
      }
    If the narrative does not contain enough evidence for any domain,
    return score: 0 and justification: "insufficient narrative evidence".
  SYS

  def self.request_answer_claude(payload_json)
    uri = URI(CLAUDE_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]      = "application/json"
    req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
    req["anthropic-version"] = CLAUDE_VERSION
    req.body = {
      model:      CLAUDE_MODEL,
      max_tokens: 600,
      system:     [{ type: "text", text: ANSWER_SYSTEM_PROMPT }],
      messages:   [{ role: "user", content: payload_json }]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: CHAT_READ_TIMEOUT) { |h| h.request(req) }
    raise "Anthropic #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("content", 0, "text").to_s
  end

  def self.request_answer_openai(payload_json)
    uri = URI(OPENAI_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]  = "application/json"
    req["authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY")}"
    req.body = {
      model:           OPENAI_MODEL,
      max_tokens:      600,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: ANSWER_SYSTEM_PROMPT },
        { role: "user",   content: payload_json }
      ]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: CHAT_READ_TIMEOUT) { |h| h.request(req) }
    raise "OpenAI #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s
  end

  def self.request_eval_fill_claude(payload_json)
    uri = URI(CLAUDE_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]      = "application/json"
    req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
    req["anthropic-version"] = CLAUDE_VERSION
    req.body = {
      model:      CLAUDE_MODEL,
      max_tokens: 2000,
      system:     [{ type: "text", text: EVAL_GAP_FILL_SYSTEM_PROMPT }],
      messages:   [{ role: "user", content: payload_json }]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    raise "Anthropic #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("content", 0, "text").to_s
  end

  def self.request_eval_fill_openai(payload_json)
    uri = URI(OPENAI_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]  = "application/json"
    req["authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY")}"
    req.body = {
      model:           OPENAI_MODEL,
      max_tokens:      2000,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: EVAL_GAP_FILL_SYSTEM_PROMPT },
        { role: "user",   content: payload_json }
      ]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    raise "OpenAI #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s
  end

  def self.request_polish_claude(raw_text)
    uri = URI(CLAUDE_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]      = "application/json"
    req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
    req["anthropic-version"] = CLAUDE_VERSION
    req.body = {
      model:      CLAUDE_MODEL,
      max_tokens: 1500,
      system:     [{ type: "text", text: POLISH_SYSTEM_PROMPT }],
      messages:   [{ role: "user", content: "Raw narrative:\n#{raw_text}" }]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 25) { |h| h.request(req) }
    raise "Anthropic #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("content", 0, "text").to_s
  end

  def self.request_polish_openai(raw_text)
    uri = URI(OPENAI_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]  = "application/json"
    req["authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY")}"
    req.body = {
      model:           OPENAI_MODEL,
      max_tokens:      1500,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: POLISH_SYSTEM_PROMPT },
        { role: "user",   content: "Raw narrative:\n#{raw_text}" }
      ]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 25) { |h| h.request(req) }
    raise "OpenAI #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s
  end

  def self.request_summary_claude(text)
    uri = URI(CLAUDE_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]      = "application/json"
    req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
    req["anthropic-version"] = CLAUDE_VERSION
    req.body = {
      model:      CLAUDE_MODEL,
      max_tokens: 300,
      system:     [{ type: "text", text: TEAM_SUMMARY_SYSTEM_PROMPT }],
      messages:   [{ role: "user", content: "Visit note:\n#{text}" }]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 20) { |h| h.request(req) }
    raise "Anthropic #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("content", 0, "text").to_s
  end

  def self.request_summary_openai(text)
    uri = URI(OPENAI_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]  = "application/json"
    req["authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY")}"
    req.body = {
      model:           OPENAI_MODEL,
      max_tokens:      300,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: TEAM_SUMMARY_SYSTEM_PROMPT },
        { role: "user",   content: "Visit note:\n#{text}" }
      ]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 20) { |h| h.request(req) }
    raise "OpenAI #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s
  end

  def self.request_speaker_tags_claude(payload_json)
    uri = URI(CLAUDE_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]      = "application/json"
    req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
    req["anthropic-version"] = CLAUDE_VERSION
    req.body = {
      model:      CLAUDE_MODEL,
      max_tokens: 2500,
      system:     [{ type: "text", text: SPEAKER_TAG_SYSTEM_PROMPT }],
      messages:   [{ role: "user", content: payload_json }]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    raise "Anthropic #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("content", 0, "text").to_s
  end

  def self.request_speaker_tags_openai(payload_json)
    uri = URI(OPENAI_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]  = "application/json"
    req["authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY")}"
    req.body = {
      model:           OPENAI_MODEL,
      max_tokens:      2500,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SPEAKER_TAG_SYSTEM_PROMPT },
        { role: "user",   content: payload_json }
      ]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 30) { |h| h.request(req) }
    raise "OpenAI #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s
  end

  def self.request_pps_claude(narrative)
    uri = URI(CLAUDE_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]      = "application/json"
    req["x-api-key"]         = ENV.fetch("ANTHROPIC_API_KEY")
    req["anthropic-version"] = CLAUDE_VERSION
    req.body = {
      model:      CLAUDE_MODEL,
      max_tokens: 250,
      system:     [{ type: "text", text: PPS_SYSTEM_PROMPT }],
      messages:   [{ role: "user", content: "Narrative:\n#{narrative}" }]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 20) { |h| h.request(req) }
    raise "Anthropic #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("content", 0, "text").to_s
  end

  def self.request_pps_openai(narrative)
    uri = URI(OPENAI_URL)
    req = Net::HTTP::Post.new(uri)
    req["content-type"]  = "application/json"
    req["authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY")}"
    req.body = {
      model: OPENAI_MODEL,
      max_tokens: 250,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: PPS_SYSTEM_PROMPT },
        { role: "user",   content: "Narrative:\n#{narrative}" }
      ]
    }.to_json
    resp = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 20) { |h| h.request(req) }
    raise "OpenAI #{resp.code}: #{resp.body.to_s[0, 300]}" unless resp.code.to_i == 200
    JSON.parse(resp.body).dig("choices", 0, "message", "content").to_s
  end

  def sanitize_clinician(parsed, source)
    audience = AUDIENCES.include?(parsed[:audience]) ? parsed[:audience] : "team"
    action   = CLINICIAN_ACTIONS.include?(parsed[:action]) ? parsed[:action] : "no_action"
    notify   = sanitize_notify_directive(parsed[:notify])
    # A notify_clinician action is meaningless without a valid relay
    # target + message. If the brain forgot the directive, fall back to
    # no_action rather than firing an empty relay.
    if action == "notify_clinician" && notify.nil?
      action = "no_action"
    end
    notify   = nil unless action == "notify_clinician"
    ack      = (action == "no_action" || action == "notify_clinician") ? nil : parsed[:ack].to_s.strip.presence
    rewrite  = parsed[:body_rewrite].to_s.strip
    rewrite  = nil if rewrite.empty? || rewrite.casecmp("null").zero?
    # Belt-and-suspenders: scrub em/en-dashes the LLM might slip in
    # despite the prompt rule. Replace with comma + space.
    rewrite  = rewrite.gsub(/\s*[—–]\s*/, ", ") if rewrite
    {
      audience:     audience,
      action:       action,
      ack:          ack,
      notify:       notify,
      body_rewrite: rewrite,
      reasoning:    parsed[:reasoning].to_s.strip,
      source:       source
    }
  end

  # Validates the notify_clinician relay directive. Returns
  # { "role" => ..., "reason" => ... } (string keys, so it survives
  # ActiveJob serialization unchanged) or nil when role/reason are
  # missing or the role isn't a relayable teammate.
  def sanitize_notify_directive(raw)
    return nil unless raw.is_a?(Hash)
    role   = (raw["role"] || raw[:role]).to_s.strip.downcase
    reason = (raw["reason"] || raw[:reason]).to_s.strip.gsub(/\s*[—–]\s*/, ", ")
    return nil unless NOTIFY_CLINICIAN_ROLES.include?(role)
    return nil if reason.empty? || reason.casecmp("null").zero?
    { "role" => role, "reason" => reason }
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
      audience:     audience,
      action:       action_intent || "no_action",
      ack:          action_intent ? "Routing your request to the right team member." : nil,
      notify:       nil,
      body_rewrite: nil,
      reasoning:    "Regex fallback (no LLM configured).",
      source:       "fallback:regex"
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
