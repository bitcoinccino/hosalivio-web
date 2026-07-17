# Triage-intent eval

Measures whether HosAlivio's family-message classifier wakes the right humans.

```bash
bin/rails eval:intents                  # regex fallback — free, offline, deterministic
bin/rails eval:intents PROVIDER=claude  # the real chain — costs money, varies run to run
bin/rails eval:intents:compare          # every configured provider side by side
```

`test/lib/intent_eval_test.rb` runs the fallback in CI. No key, no network, no cost.

## Why routing, not accuracy

The classifier's output is not a label, it's a page. `ESCALATION_ROLES` turns the
intent into people:

```ruby
pain_crisis     -> [visit_rn, md]
dyspnea         -> [visit_rn, md]
status_question -> [visit_rn]
```

Calling a pain crisis `dyspnea` is a wrong label but the **same two people are
paged** — nobody is harmed. Calling it `status_question` silently drops the MD.
A plain accuracy score gives both mistakes the same weight, which is wrong in a
way that matters here. So results are tiered:

| tier | meaning | severity |
|---|---|---|
| `missed_escalation` | expected roles not all notified | **the number that matters** |
| `over_escalation` | extra roles notified | costs sleep, not safety |
| `label_only` | same roles, different label | cosmetic |
| `exact` | label matches | — |

`bin/rails eval:intents` exits non-zero on any missed escalation. Nothing else
fails the run.

Recall is reported per intent, and precision is not. Deliberate: a missed pain
crisis is someone in pain; a false positive is a nurse checking on someone who
is fine.

## What it caught

First run, immediately:

```
dyspnea_described    dyspnea -> status_question    missing: md
```

`/\bbreath\b/` does not match `"breathes"` — the word boundary fails on the
trailing `es`. So *"rattling sound when he breathes, working hard for each one"*
fell past the dyspnea branch and matched `status_question` on the word
**"when"**. A respiratory crisis became a scheduling question, and the MD was
never paged. Fixed by stemming (`breath\w*`) and moving the respiratory check
above pain, since "gasping" is breathing, not pain.

That bug was live and invisible. It is the argument for this directory.

## The `fallback_ok: false` ledger

Cases the regex provably cannot reach — understatement, behavioural description,
caregiver distress, mis-flagged urgency. They are **excluded from the fallback
score** so the run has a meaningful pass/fail, but printed after every run so the
gap never goes quiet.

They are the cost of the API being down. An LLM run should get them — that
difference is the measurable value of the LLM, and `eval:intents:compare` is
where you read it.

## Adding cases

Add the real message whenever triage gets one wrong in production. Verbatim —
lowercase, typos, hedging, apology. Families do not write clean prose, and a
dataset of clean prose measures nothing.

This file only earns its keep if it accumulates the failures you actually saw.

## What this does not measure

- **Reply quality.** Only intent. The lay-friendly reply text is unscored.
- **Urgency.** `decision[:urgency]` drives the CRISIS pill; not yet scored.
- **The clinician dispatcher.** `ClinicianDispatcher::INTENT_MAP` is a separate
  regex classifier with no eval at all.
- **Drift.** One run is a snapshot. Nothing tracks scores across model versions.
