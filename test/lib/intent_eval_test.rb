require "test_helper"
require Rails.root.join("lib/eval/intent_runner")

# Pins the regex fallback in HosalivioBrain#fallback against the labelled set.
#
# This runs in CI because it needs no API key, no network and no money — and
# the fallback is precisely the path that runs when the LLM providers are down,
# i.e. when nobody is watching it. It is the classifier most likely to rot
# unnoticed, so it is the one worth a test.
#
# The LLM providers are NOT tested here: they cost money and are
# non-deterministic. Score those on demand with `bin/rails eval:intents
# PROVIDER=claude`.
class IntentEvalTest < ActiveSupport::TestCase
  setup { @scorer = Eval::IntentRunner.new(provider: :fallback).run }

  test "the fallback never drops a role the intent should have escalated to" do
    # THE assertion. A wrong label is survivable; a family in a pain crisis
    # whose MD was never paged is not. If this fails, read the report — it names
    # the case and the missing role.
    assert_empty @scorer.missed_escalations.map(&:id),
                 "\n#{@scorer.report}\n\nA case routed to fewer people than it should have."
  end

  test "the fallback routes every scored case correctly" do
    assert_equal "100%", @scorer.routing_accuracy, "\n#{@scorer.report}"
  end

  test "respiratory wording reaches dyspnea rather than falling through to status_question" do
    # Regression: /\bbreath\b/ did not match "breathes", so "rattling when he
    # breathes" matched the status_question branch on the word "when" and lost
    # the MD. Guard the word forms, not just the aggregate score.
    %w[breathes breathing breathe gasping rattling wheezing].each do |word|
      note   = Note.new(patient: Patient.new(first_name: "E", last_name: "P", dob: Date.new(1940, 1, 1)),
                        body: "there is a #{word} problem and i don't know when it started",
                        urgency: "normal", source: "family_portal")
      intent = HosalivioBrain.new(note).send(:fallback, reason: "test")[:intent]
      assert_equal "dyspnea", intent, "#{word.inspect} should classify as dyspnea, got #{intent}"
    end
  end

  test "a crisis flag escalates to the MD even when the wording is unfamiliar" do
    # The fallback trusts a crisis flag over the text. That over-escalates a
    # mis-flagged message, which is the right trade for a regex running blind.
    note   = Note.new(patient: Patient.new(first_name: "E", last_name: "P", dob: Date.new(1940, 1, 1)),
                      body: "something is very wrong but i cannot describe it",
                      urgency: "crisis", source: "family_portal")
    intent = HosalivioBrain.new(note).send(:fallback, reason: "test")[:intent]
    assert_includes HosalivioTriager::ESCALATION_ROLES.fetch(intent), "md"
  end

  test "the dataset stays honest" do
    runner = Eval::IntentRunner.new(provider: :fallback)
    ids    = runner.cases.map { |c| c["id"] }
    assert_equal ids.uniq, ids, "duplicate case ids"

    runner.cases.each do |c|
      assert HosalivioBrain::INTENTS.include?(c["expect"]),
             "#{c['id']}: expects #{c['expect'].inspect}, which is not a real intent"
      assert HosalivioTriager::ESCALATION_ROLES.key?(c["expect"]),
             "#{c['id']}: #{c['expect']} has no route"
      assert Note.urgencies.key?(c.fetch("family_urgency", "normal")),
             "#{c['id']}: #{c['family_urgency'].inspect} is not a real urgency"
    end
  end

  test "every intent that can be routed has at least one case" do
    covered = Eval::IntentRunner.new(provider: :fallback).cases.map { |c| c["expect"] }.uniq
    missing = HosalivioBrain::INTENTS - covered
    assert_empty missing, "intents with no labelled case — they are unmeasured: #{missing.join(', ')}"
  end
end
