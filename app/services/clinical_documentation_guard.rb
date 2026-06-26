# Post-generation check on LLM output before it lands in the chart.
#
# Runs AFTER AgentBrain returns a decision and BEFORE AgentTriager writes
# anything to the DB. Scans the chart-bound fields (write_note.body,
# write_visit.narrative) for:
#
#   1. Hedging phrases ("probably", "might", "seems", "doing okay")
#   2. Forbidden topics in chart prose (politics, sports, gossip, etc.)
#   3. Ungrounded numeric claims (weight, pain, BP, SpO2, HR, temp values
#      that do not appear in the input context)
#   4. Placeholder/TODO tokens that suggest the LLM didn't actually write
#
# If any check fails, the decision is replaced with no_action and the
# failure reasons ride along in the reasoning for compliance audit logs.
# No DB write happens. Nothing pollutes the clinical chart.
#
# Family-facing broadcast_reply content is exempt: it needs warm plain
# English and hedges are sometimes appropriate there ("we think", "usually").

class ClinicalDocumentationGuard
  Result = Struct.new(:passed, :reasons, :decision, keyword_init: true) do
    alias_method :passed?, :passed
  end

  # Only chart-bound fields are scanned. broadcast_reply is intentionally
  # absent; its voice follows different rules.
  CHART_BOUND_FIELDS = {
    "write_note"  => %i[body],
    "write_visit" => %i[narrative]
  }.freeze

  HEDGE_PATTERNS = [
    /\bdoing\s+okay\b/i,
    /\bseems\s+fine\b/i,
    /\bprobably\b/i,
    /\bmight\s+be\b/i,
    /\bmaybe\b/i,
    /\bappears\s+to\s+be\b/i,
    /\bpossibly\b/i,
    /\blikely\b/i,
    /\bI\s+think\b/i
  ].freeze

  FORBIDDEN_TOPIC_PATTERNS = [
    /\b(republican|democrat|election|voting|politics|political)\b/i,
    /\b(football|baseball|basketball|soccer|nfl|nba|mlb|sports\s+game|fantasy\s+league)\b/i,
    /\b(celebrity|gossip|tv\s+show|netflix|movie\s+premiere)\b/i,
    /\b(weather\s+forecast|sunny\s+day|rainy\s+day)\b/i
  ].freeze

  # Patterns for numeric clinical claims. Captures the number(s) for grounding
  # verification against the input context.
  NUMERIC_CLAIM_PATTERNS = [
    { label: "weight",   pattern: /\b(\d+(?:\.\d+)?)\s*(?:lbs?|pounds?|kg)\b/i },
    { label: "BP",       pattern: /\b(\d{2,3})\s*\/\s*(\d{2,3})\s*(?:mmHg)?\b/ },
    { label: "pain",     pattern: /\b(\d{1,2})\s*\/\s*10\s*(?:pain)?\b/i },
    { label: "pulse",    pattern: /\b(\d{2,3})\s*(?:bpm|beats\/min|pulse|HR)\b/i },
    { label: "SpO2",     pattern: /\b(\d{2,3})\s*%?\s*(?:SpO2|O2\s*sat|oxygen\s+sat)\b/i },
    { label: "temp",     pattern: /\btemp(?:erature)?\s*(?:of\s*)?(\d{2,3}(?:\.\d+)?)\s*(?:F|C|°)?/i },
    { label: "weight_loss", pattern: /\b(\d+(?:\.\d+)?)\s*(?:lbs?|pounds?|kg)\s+(?:weight\s+)?loss\b/i }
  ].freeze

  PLACEHOLDER_TOKENS = [
    "[describe]", "[TODO]", "[TBD]", "[fill in]", "...", "N/A chart"
  ].freeze

  def self.check(role:, decision:, context:)
    new(role, decision, context).check
  end

  def initialize(role, decision, context)
    @role     = role.to_s
    @decision = decision || {}
    @context  = context || {}
  end

  def check
    return pass unless should_check?

    text = chart_text
    return pass if text.blank?

    reasons = []
    reasons.concat(scan_hedges(text))
    reasons.concat(scan_forbidden_topics(text))
    reasons.concat(scan_ungrounded_numbers(text))
    reasons.concat(scan_placeholders(text))

    reasons.any? ? fail_and_replace(reasons) : pass
  end

  # ──────────────────────────────────────────────────────────────────

  private

  def should_check?
    return false unless AgentBrain::ROLES_REQUIRING_DOCUMENTATION_DISCIPLINE.include?(@role)
    CHART_BOUND_FIELDS.key?(@decision[:action].to_s)
  end

  def chart_text
    fields = CHART_BOUND_FIELDS[@decision[:action].to_s]
    params = @decision[:params].is_a?(Hash) ? @decision[:params].with_indifferent_access : {}
    fields.map { |f| params[f].to_s.strip }.reject(&:empty?).join("\n")
  end

  def scan_hedges(text)
    HEDGE_PATTERNS.flat_map do |pat|
      matches = text.scan(pat)
      matches.any? ? [ "hedging phrase (#{first_match(pat, text)})" ] : []
    end
  end

  def scan_forbidden_topics(text)
    FORBIDDEN_TOPIC_PATTERNS.flat_map do |pat|
      text.scan(pat).any? ? [ "forbidden topic in chart text (#{first_match(pat, text)})" ] : []
    end
  end

  def scan_placeholders(text)
    PLACEHOLDER_TOKENS.flat_map do |token|
      text.include?(token) ? [ "placeholder token (#{token})" ] : []
    end
  end

  # For each numeric claim the LLM made in the chart, confirm that exact
  # number appears somewhere in the context we passed to it. If it doesn't,
  # the model invented a number — the highest-risk failure mode.
  def scan_ungrounded_numbers(text)
    haystack = context_text
    findings = []
    NUMERIC_CLAIM_PATTERNS.each do |entry|
      text.scan(entry[:pattern]).each do |captured|
        Array(captured).flatten.compact.each do |num|
          next if num.to_s.empty?
          unless haystack.include?(num.to_s)
            findings << "ungrounded #{entry[:label]} value (#{num} not in input context)"
          end
        end
      end
    end
    findings
  end

  # Flatten the context hash into a searchable blob we can scan for grounding.
  def context_text
    return @context_text if defined?(@context_text)
    parts = []
    if @context[:patient].is_a?(Hash)
      @context[:patient].each { |k, v| parts << "#{k}=#{v}" }
    end
    parts.concat(Array(@context[:active_meds]))
    Array(@context[:recent_notes]).each { |n| parts << n[:body].to_s }
    parts << @context[:intent].to_s
    parts << @context[:urgency].to_s
    @context_text = parts.join(" ").downcase
  end

  def first_match(pattern, text)
    m = text.match(pattern)
    m ? m[0] : "—"
  end

  def pass
    Result.new(passed: true, reasons: [], decision: @decision)
  end

  def fail_and_replace(reasons)
    Rails.logger.warn(
      "[ClinicalDocumentationGuard] BLOCKED role=#{@role} action=#{@decision[:action]} " \
      "reasons=#{reasons.inspect} original_source=#{@decision[:source]} " \
      "original_text=#{chart_text.inspect[0, 240]}"
    )
    replaced = @decision.merge(
      action:    "no_action",
      params:    {},
      reasoning: "Blocked by ClinicalDocumentationGuard: #{reasons.join('; ')}. " \
                 "Original brain reasoning: #{@decision[:reasoning]}",
      source:    "#{@decision[:source]}+guard:blocked"
    )
    Result.new(passed: false, reasons: reasons, decision: replaced)
  end
end
