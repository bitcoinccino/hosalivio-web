# Evaluate HosAlivio's triage-intent classifier against the labelled set in
# lib/eval/family_intents.yml.
#
#   bin/rails eval:intents                    # regex fallback — free, offline
#   bin/rails eval:intents PROVIDER=claude    # the real chain — costs money
#   bin/rails eval:intents:compare            # every configured provider
#
# Scored on ROUTING, not labels — see lib/eval/intent_scorer.rb.

namespace :eval do
  desc "Score the triage-intent classifier (PROVIDER=fallback|claude|openai|openrouter)"
  task intents: :environment do
    require Rails.root.join("lib/eval/intent_runner")

    provider = (ENV["PROVIDER"].presence || "fallback").to_sym
    if provider != :fallback && !HosalivioBrain.enabled?(provider)
      abort "  #{provider} has no API key configured — set it in .env, or run with PROVIDER=fallback."
    end

    ds = ENV["DATASET"].presence
    runner = ds ? Eval::IntentRunner.new(provider: provider, dataset: ds) : Eval::IntentRunner.new(provider: provider)
    puts "\n  provider: #{provider}   cases: #{runner.scored_cases.size}"
    if provider == :fallback && runner.known_fallback_gaps.any?
      puts "  (#{runner.known_fallback_gaps.size} cases marked fallback_ok:false are excluded — see the ledger below)"
    end

    scorer = runner.run
    puts scorer.report

    if provider == :fallback && runner.known_fallback_gaps.any?
      puts "\n  KNOWN FALLBACK GAPS — cases the regex cannot reach, excluded above:"
      runner.known_fallback_gaps.each do |c|
        puts format("      %-24s expect %-20s %s", c["id"], c["expect"], c["why"].to_s[0, 60])
      end
      puts "  These are the cost of the API being down. An LLM run should get them."
    end

    abort "\n  INVALID: #{scorer.errors.size} case(s) errored — the run measured nothing about them." unless scorer.valid?
    abort "\n  FAILED: #{scorer.missed_escalations.size} missed escalation(s)." if scorer.missed_escalations.any?
    puts "\n  OK — every case routed to at least the right people.\n\n"
  end

  namespace :intents do
    # Exports REAL family messages as a labelling worksheet for a clinician.
    #
    # lib/eval/family_intents.yml is invented — messages an LLM imagined a
    # hospice family might send, labelled with that same LLM's opinion of
    # hospice triage. It measures two models agreeing with each other. This task
    # replaces that with the actual traffic.
    #
    # It reconstructs the thread exactly as HosalivioTriager#recent_thread_context
    # does, because 45 of 46 real messages arrive mid-conversation ("The whole
    # kit.", "What should i do ?") and are meaningless alone.
    #
    # PHI: the output contains real family message bodies. It defaults to tmp/
    # (gitignored) and omits names/MRNs — patients are referred to by index.
    # Do not commit the result, and do not paste it anywhere.
    desc "Export real family messages + HosAlivio's decision as a labelling worksheet"
    task harvest: :environment do
      out   = ENV.fetch("OUT", Rails.root.join("tmp/harvested_intents.yml").to_s)
      limit = Integer(ENV.fetch("LIMIT", 100))

      family = Note.where(author_role: "family", source: "text").order(:created_at).limit(limit)
      abort "  No family messages found." if family.empty?

      pt_index = {}
      rows = family.map.with_index do |note, i|
        pt_index[note.patient_id] ||= "patient_#{pt_index.size + 1}"

        # Mirrors HosalivioTriager#recent_thread_context: last 8 family-visible
        # notes before this one, oldest first.
        context = Note.where(patient_id: note.patient_id, clinician_only: [ nil, false ])
                      .where("created_at < ?", note.created_at)
                      .order(created_at: :desc).limit(8).reverse
                      .map { |n| { "role" => (n.ai_authored? ? "hosalivio" : (n.author_role == "family" ? "family" : "clinician")),
                                   "body" => n.body.to_s[0, 300] } }

        # What HosAlivio actually did. TWO paths escalate and they leave
        # different traces — reading only one badly misreports the other as
        # "nobody was told":
        #   emit_handoff    -> AgentEvent(action: handoff), carries the intent
        #   execute_notify  -> Notification to a named clinician, NO AgentEvent
        # Both wake a human. Only the first is in the agent audit trail.
        window = note.created_at..(note.created_at + 2.minutes)
        ev = AgentEvent.where(agent_id: %w[triage admissions], action: "handoff",
                              subject_type: "Patient", subject_id: note.patient_id)
                       .where(happened_at: window).order(:happened_at).first
        said = ev&.change_set.is_a?(Hash) ? ev.change_set["intent"] : nil

        notified = Notification.where(created_at: window, kind: "mentioned")
                               .filter_map { |n| n.user&.full_name }.uniq

        {
          "id"             => "real_#{format('%03d', i + 1)}",
          "patient"        => pt_index[note.patient_id],
          "message"        => note.body.to_s,
          "family_urgency" => note.urgency.to_s,
          "context"        => context,
          "hosalivio_said" => said,          # intent, when it took the handoff path
          "woke"           => notified,      # humans actually notified (either path)
          "expect"         => "TODO",        # ← clinician fills this in
          "why"            => ""
        }
      end

      opening = rows.count { |r| r["context"].empty? }
      File.write(out, {
        "_instructions" => "Set `expect` on each case to the intent a competent triage nurse would assign: " \
                           "#{HosalivioBrain::INTENTS.join(' | ')}. " \
                           "`hosalivio_said` is what SHIPPED, not the answer — disagreeing with it is the point. " \
                           "Read `context` first; most messages are replies. Delete cases you cannot judge.",
        "cases" => rows
      }.to_yaml)

      puts "\n  wrote #{rows.size} real messages → #{out}"
      puts "  #{rows.size - opening} of #{rows.size} arrive mid-conversation (context included)"
      puts "  #{rows.count { |r| r['hosalivio_said'].nil? }} have no recorded handoff (HosAlivio routed nothing, or pre-dates the events)"
      puts "\n  ⚠ contains real family message bodies. tmp/ is gitignored — keep it that way."
      puts "  Next: a clinician sets `expect` on each, then point the runner at it:"
      puts "      bin/rails eval:intents PROVIDER=openrouter DATASET=#{out}\n\n"
    end

    # A single run against a sampling model is an anecdote, not a measurement.
    # This runs the whole set N times and reports which cases give different
    # answers to the identical message — and whether any flip drops a role.
    desc "Measure run-to-run stability (RUNS=5 PROVIDER=openrouter)"
    task stability: :environment do
      require Rails.root.join("lib/eval/intent_runner")

      provider = (ENV["PROVIDER"].presence || "openrouter").to_sym
      runs     = Integer(ENV.fetch("RUNS", 5))
      abort "  #{provider} has no API key configured." if provider != :fallback && !HosalivioBrain.enabled?(provider)

      seen       = Hash.new { |h, k| h[k] = [] }
      errors     = 0
      @case_ids  = Eval::IntentRunner.new(provider: provider).scored_cases.map { |c| c["id"] }
      runs.times do |i|
        print "  run #{i + 1}/#{runs}… "
        scorer = Eval::IntentRunner.new(provider: provider).run
        errors += scorer.errors.size
        scorer.results.each { |r| seen[r.id] << r.predicted }
        puts "routed #{scorer.routing_accuracy}#{scorer.errors.any? ? " (#{scorer.errors.size} errored)" : ''}"
      end

      scorer = Eval::IntentScorer.new
      flappy = seen.select { |_, preds| preds.uniq.size > 1 }
      puts "\n  temperature: #{HosalivioBrain::TRIAGE_TEMPERATURE}   provider: #{provider}   runs: #{runs}"
      puts "  " + "─" * 66

      # A case that errors often yields too few samples to compare, and would
      # otherwise be reported as "stable" — the exact opposite of the truth. The
      # first version of this task did that: it called the set deterministic
      # while the flappiest case was flipping 50/50 behind a wall of errors.
      thin = seen.select { |_, preds| preds.size < 2 }.keys
      thin += (@case_ids.to_a - seen.keys) if defined?(@case_ids)
      if thin.any?
        puts "  ⚠ NOT MEASURED — too few successful runs to judge stability:"
        thin.uniq.each { |id| puts format("      %-24s %d/%d runs returned an answer", id, seen[id].size, runs) }
        puts "    Treat these as unknown, not stable.\n\n"
      end

      if flappy.empty?
        puts(thin.any? ? "  ~ every case that WAS measured agreed across runs (see unmeasured above)."
                       : "  ✓ DETERMINISTIC — every case gave the same answer on all #{runs} runs.")
      else
        puts "  ✗ #{flappy.size} case(s) gave different answers to the identical message:\n\n"
        flappy.each do |id, preds|
          tally = preds.tally.sort_by { |_, n| -n }.map { |p, n| "#{p}×#{n}" }.join("  ")
          roles = preds.uniq.map { |p| scorer.roles_for(p) }
          drops = roles.flatten.uniq - roles.reduce(:&)
          puts format("      %-24s %s", id, tally)
          puts format("      %-24s %s", "", drops.any? ? "⚠ routing differs — #{drops.join(', ')} paged on some runs only" : "same route either way — cosmetic")
        end
      end
      puts "\n  #{errors} provider error(s) across #{runs} runs." if errors.positive?
      puts
    end

    desc "Score every configured provider side by side"
    task compare: :environment do
      require Rails.root.join("lib/eval/intent_runner")

      providers = [ :fallback ] + HosalivioBrain::PROVIDER_CHAIN.select { |p| HosalivioBrain.enabled?(p) }
      rows = providers.map do |p|
        runner = Eval::IntentRunner.new(provider: p)
        s = runner.run
        [ p, s.count, s.intent_accuracy, s.routing_accuracy, s.missed_escalations.size ]
      end

      puts "\n  #{'provider'.ljust(12)} #{'n'.rjust(4)}  #{'intent'.rjust(7)}  #{'routed'.rjust(7)}  missed-escalations"
      puts "  " + "─" * 58
      rows.each { |p, n, ia, ra, me| puts format("  %-12s %4d  %7s  %7s  %s", p, n, ia, ra, me.zero? ? "0" : "#{me}  ← ") }
      puts "\n  Only :fallback is comparable run-to-run; LLM providers vary.\n\n"
    end
  end
end
