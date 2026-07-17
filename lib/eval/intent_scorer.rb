# Scores triage-intent predictions.
#
# The headline number is NOT intent accuracy. The classifier exists to wake the
# right humans, so it is scored against the roles its intent routes to via
# HosalivioTriager::ESCALATION_ROLES:
#
#   pain_crisis  -> [visit_rn, md]
#   dyspnea      -> [visit_rn, md]
#
# Predicting dyspnea for a pain crisis is a wrong LABEL but a correct ROUTE —
# the same two people get paged. Predicting status_question (-> [visit_rn])
# silently drops the MD. Those two mistakes are not the same size, and a plain
# accuracy score cannot tell them apart.
#
# Hence three tiers, worst first:
#
#   missed_escalation  expected roles NOT all notified. Someone who should have
#                      been woken was not. This is the number that matters.
#   over_escalation    extra roles notified. Costs trust and sleep, not safety.
#   label_only         roles identical, label different. Cosmetic.
#
# Usage:
#   scorer = Eval::IntentScorer.new
#   scorer.record(id: "pain_obvious", expected: "pain_crisis", predicted: "dyspnea")
#   scorer.report   # => formatted string
#   scorer.missed_escalations   # => [Result, ...]

module Eval
  class IntentScorer
    Result = Struct.new(:id, :expected, :predicted, :expected_roles, :predicted_roles,
                        :tier, :message, keyword_init: true) do
      def correct?  = tier == :exact
      def routed_ok? = %i[exact label_only over_escalation].include?(tier)
    end

    Failure = Struct.new(:id, :error, :message, keyword_init: true)

    attr_reader :results, :errors

    def initialize
      @results = []
      @errors  = []
    end

    # A provider that errored produced NO prediction. Recording it as one (an
    # earlier version substituted "other") turns an outage into a fake accuracy
    # signal — the run reads as "the model was wrong" when the truth is "the
    # model never answered". Errors are counted apart and invalidate the run.
    def record_error(id:, error:, message: nil)
      @errors << Failure.new(id: id, error: error, message: message)
    end

    def roles_for(intent)
      HosalivioTriager::ESCALATION_ROLES.fetch(intent.to_s, HosalivioTriager::ESCALATION_ROLES["other"])
    end

    def record(id:, expected:, predicted:, message: nil)
      exp_roles = roles_for(expected).sort
      got_roles = roles_for(predicted).sort

      tier =
        if expected.to_s == predicted.to_s          then :exact
        elsif exp_roles == got_roles                then :label_only
        elsif (exp_roles - got_roles).any?          then :missed_escalation
        else                                             :over_escalation
        end

      @results << Result.new(id: id, expected: expected.to_s, predicted: predicted.to_s,
                             expected_roles: exp_roles, predicted_roles: got_roles,
                             tier: tier, message: message)
    end

    def count               = @results.size
    def tier(name)          = @results.select { |r| r.tier == name }
    def missed_escalations  = tier(:missed_escalation)
    def over_escalations    = tier(:over_escalation)
    def routed_ok           = @results.count(&:routed_ok?)
    def exact               = @results.count(&:correct?)

    def intent_accuracy = pct(exact, count)
    def routing_accuracy = pct(routed_ok, count)

    # Per-intent recall — of the cases that SHOULD be X, how many were?
    # Recall matters more than precision here: a missed pain crisis is a person
    # in pain; a false positive is a nurse checking on someone who is fine.
    def recall_by_intent
      @results.group_by(&:expected).transform_values do |rs|
        hit = rs.count { |r| r.predicted == r.expected }
        { hit: hit, total: rs.size, pct: pct(hit, rs.size) }
      end
    end

    def confusions
      @results.reject(&:correct?)
              .group_by { |r| [ r.expected, r.predicted ] }
              .transform_values(&:size)
              .sort_by { |_, n| -n }
    end

    # A run with errors measured nothing about those cases — say so rather than
    # quietly scoring the rest as if the set were complete.
    def valid? = @errors.empty?

    def report
      lines = []
      lines << "─" * 72
      lines << format("  scored: %d   intent-exact: %s   ROUTED CORRECTLY: %s", count, intent_accuracy, routing_accuracy)
      lines << format("  ⚠ %d case(s) ERRORED — not scored. This run is incomplete.", @errors.size) if @errors.any?
      lines << "─" * 72

      if @errors.any?
        lines << ""
        lines << "  ! PROVIDER ERRORS (#{@errors.size}) — no prediction, not a wrong answer:"
        @errors.each do |f|
          lines << format("      %-24s %s: %s", f.id, f.error.class, f.error.message.to_s[0, 60])
        end
        lines << ""
      end

      if missed_escalations.any?
        lines << ""
        lines << "  ✗ MISSED ESCALATIONS (#{missed_escalations.size}) — someone was not woken:"
        missed_escalations.each do |r|
          lines << format("      %-24s %s -> %s", r.id, r.expected, r.predicted)
          lines << format("      %-24s wanted %-28s got %s", "", r.expected_roles.join("+"), r.predicted_roles.join("+"))
          lines << format("      %-24s missing: %s", "", (r.expected_roles - r.predicted_roles).join(", "))
          lines << format("      %-24s \"%s\"", "", r.message.to_s[0, 70]) if r.message
          lines << ""
        end
      else
        lines << "  ✓ no missed escalations"
      end

      if over_escalations.any?
        lines << "  ~ over-escalations (#{over_escalations.size}) — extra people paged, not unsafe:"
        over_escalations.each { |r| lines << format("      %-24s %s -> %s (+%s)", r.id, r.expected, r.predicted, (r.predicted_roles - r.expected_roles).join(",")) }
        lines << ""
      end

      if tier(:label_only).any?
        lines << "  · label-only diffs (#{tier(:label_only).size}) — same route, cosmetic:"
        tier(:label_only).each { |r| lines << format("      %-24s %s -> %s", r.id, r.expected, r.predicted) }
        lines << ""
      end

      lines << "  recall by intent:"
      recall_by_intent.sort_by { |_, v| v[:pct].to_f }.each do |intent, v|
        bar = "█" * (v[:pct].to_f / 10).round
        lines << format("      %-20s %5s  %-10s (%d/%d)", intent, v[:pct], bar, v[:hit], v[:total])
      end

      if confusions.any?
        lines << ""
        lines << "  top confusions:"
        confusions.first(5).each { |(exp, got), n| lines << format("      %-20s -> %-20s x%d", exp, got, n) }
      end

      lines << "─" * 72
      lines.join("\n")
    end

    private

    def pct(n, d) = d.zero? ? "n/a" : format("%.0f%%", (n.to_f / d) * 100)
  end
end
