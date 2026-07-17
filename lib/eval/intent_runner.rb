# Runs lib/eval/family_intents.yml through the triage classifier and scores it.
#
# Builds in-memory Note/Patient objects — nothing is written, no tenant needed,
# no chart touched. The classifier only reads body/urgency/source off the note
# and a few assignment names off the patient.
#
# Providers:
#   :fallback  the regex classifier in HosalivioBrain#fallback. Free,
#              deterministic, offline — and it is what runs when the API is
#              down, i.e. exactly when nobody is watching. Pinned by a test.
#   :claude / :openai / :openrouter
#              the real chain. Costs money, needs a key, non-deterministic.
#              Run on demand via rake.
#
#   Eval::IntentRunner.new(provider: :fallback).run   # => Eval::IntentScorer

require_relative "intent_scorer"

module Eval
  class IntentRunner
    DATASET = File.expand_path("family_intents.yml", __dir__)

    attr_reader :cases

    def initialize(provider: :fallback, dataset: DATASET)
      @provider = provider.to_sym
      @cases    = YAML.load_file(dataset).fetch("cases")
                      .reject { |c| c["expect"].to_s == "TODO" }   # unlabelled worksheet rows
    end

    # Cases the regex fallback is not expected to get right. Skipped when
    # scoring :fallback so the run has a meaningful pass/fail, but counted and
    # reported so the gap never goes quiet.
    def known_fallback_gaps = @cases.reject { |c| c.fetch("fallback_ok", true) }

    def scored_cases
      @provider == :fallback ? @cases.select { |c| c.fetch("fallback_ok", true) } : @cases
    end

    def run
      scorer = IntentScorer.new
      scored_cases.each do |c|
        predicted = classify(c)
        if predicted.is_a?(StandardError)
          scorer.record_error(id: c["id"], error: predicted, message: c["message"])
        else
          scorer.record(id: c["id"], expected: c["expect"], predicted: predicted, message: c["message"])
        end
      end
      scorer
    end

    private

    # Returns the intent, or the exception itself — NEVER a substitute intent.
    #
    # This previously rescued to "other", which made an HTTP timeout
    # indistinguishable from the model answering "other". A dropped request then
    # showed up in the report as a missed escalation on an obvious dyspnea case,
    # and there was no way to tell the two apart after the fact. An error is not
    # a prediction; it is the absence of one.
    def classify(c)
      brain = HosalivioBrain.new(note_for(c), thread_context: thread_context_for(c))
      if @provider == :fallback
        brain.send(:fallback, reason: "eval")[:intent]
      else
        brain.send(:attempt, @provider)[:intent]
      end
    rescue StandardError => e
      e
    end

    # 45 of 46 real family messages arrive mid-conversation — "The whole kit.",
    # "What should i do ?" — and mean nothing alone. The triager always passes
    # thread_context for exactly that reason, so an eval that omits it is
    # measuring a mode the product does not have. Shape mirrors
    # HosalivioTriager#recent_thread_context.
    def thread_context_for(c)
      Array(c["context"]).map do |m|
        { role: m["role"], body: m["body"].to_s[0, 600], sent_at: Time.current.iso8601 }
      end.presence
    end

    # Unsaved — the classifier reads attributes only.
    def note_for(c)
      Note.new(
        patient: patient,
        body:    c["message"],
        urgency: c.fetch("family_urgency", "normal"),
        source:  "family_portal"
      )
    end

    def patient
      @patient ||= Patient.new(
        first_name: "Eval", last_name: "Patient",
        dob: Date.new(1940, 1, 1), primary_diagnosis: "End-stage COPD", code_status: "dnr"
      )
    end
  end
end
