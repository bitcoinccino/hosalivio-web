# Prior-Authorization Review — First-Slice Design

Status: **planning (new vertical, outside MVP1)** · Target branch: `feat/prior-auth-slice`

Goal: extend the existing **hospice-LCD engine** into a general **medical-necessity /
prior-authorization review** tool, without greenfielding. A reviewer uploads a
request + supporting records; HosAlivio validates the provider and codes, pulls
the governing Medicare coverage policy, extracts **verified** evidence for each
policy criterion, lists documentation gaps, and drafts an approve / gap / deny
recommendation — which a human signs off before it leaves.

This is the same shape the hospice pre-admit engine already runs (validate → find
policy → check criteria → flag gaps → recommend → sign-off). The new work is a
**procedure-code layer**, a **data-driven policy/criteria model**, and a
**grounded document-evidence pipeline**. It is a distinct product line from the
hospice tool and is **not** part of the locked MVP1 (admission scribe + family
chat) — keep it a spec until we decide to pursue it.

---

## 1. Scope of the first slice

**In:**
- **Medicare only.** LCD/NCD coverage via the existing `Cms::CoverageApi` client.
- **HCPCS Level II only** (public domain). No AMA CPT (licensed — see §7).
- **One seeded policy** end-to-end. Criteria hand-entered from a real LCD/NCD.
- **Digital PDFs / DOCX** with a text layer. Scanned faxes → "manual review".
- **Grounding verification** on every extracted quote (§4, the trust gate).
- **Human sign-off** before any recommendation is final.

**Deliberately out (later ladder rungs, not blockers):**
Fax/OCR & vision, embeddings/pgvector retrieval, commercial-payer policies,
CPT procedures, multi-policy routing, auto-submission to a payer.

## 2. Non-negotiables (what makes it defensible)

1. **Every ✓ traces to verbatim source text** a reviewer can click to — proven by
   the Stage-3 harness, never by the model's say-so.
2. **Never-infer extraction.** Reuse the conservative law from
   `PreAdmitNarrativeExtractor` — a criterion is "met" only on explicit evidence.
3. **Human signs off before anything leaves** — the app's locked principle.
4. **Fail loud.** Unreadable/scanned input → "route to manual review", never a
   silent pass (same discipline as `stage_intake_suggestions`' rescue).

## 3. Reuse vs. new

| Reuse (already in repo) | New (build) |
|---|---|
| `Cms::CoverageApi` — CMS license-token + LCD/NCD fetch, cache, fallback | Generalize past the `hospice` title filter; code-indexed lookup |
| `Cms::HospiceCoverage` — code → policy mapping pattern | `Coding::Hcpcs` procedure validation |
| `PreAdmitValidator` — errors-block / warnings-surface gate | **Grounding-verification** service (Stage 3) |
| `PreAdmitNarrativeExtractor` — never-infer extraction law | Criterion-anchored extractor (Stage 2) |
| `icd_evidence` (`app/helpers/icd_helper.rb`) — keyword snippet anchoring | Generalize to criterion → evidence |
| `Coding::Npi` (single-match trust), `Coding::Icd10` | — |
| `HosalivioBrain` — Claude→OpenAI→OpenRouter chain, JSON mode | (text-only today; OCR/vision is a later slice) |
| `PatientDocument` + `rails_blob_path` | `DocumentText` page-mapped extraction — needs `pdf-reader` (+ `docx`) |
| `AgentEvent` audit; intake-suggestions review-card pattern | `PriorAuthReview` + `CriterionResult` models & UI |
| Postgres (`gen_random_uuid()`, `acts_as_tenant`) | `pgvector`/`neighbor` **only if** retrieval is later needed |

## 4. The pipeline (6 stages)

```
PatientDocument (upload)
  → 0. Extract text + page map (DocumentText)
  → 1. (optional) Retrieve per criterion       ← keyword-only in slice 1
  → 2. Criterion-anchored LLM extraction (HosalivioBrain)
  → 3. GROUNDING VERIFICATION  ← the trust gate; build FIRST
  → 4. Assemble CriterionResults + gaps + drafted recommendation
  → 5. Human review + sign-off
```

**Stage 0 — `DocumentText`.** `pdf-reader` → text **per page** (retain page
numbers for citation); `docx` gem for Word. No OCR in slice 1 — a page with an
empty text layer marks the doc `needs_manual_review`. Persist page-mapped text,
`encrypts` it (PHI, like `narrative`/`intake_extras`), cache so re-runs don't
re-parse.

**Stage 1 — Retrieval.** Short docs fit context → skip. For long records,
generalize `icd_evidence_keywords`: each `PolicyCriterion` carries keywords; match
to pages; pass top-k pages per criterion. Embeddings deferred.

**Stage 2 — Criterion-anchored extraction.** `HosalivioBrain` with the criteria
list + page-marked text. Forced schema (JSON mode on Claude/OpenAI; prompt-only on
the GLM path per the existing `oai_chat` caveat):

```json
[{ "criterion_id": "...",
   "verdict": "met | unmet | not_documented | uncertain",
   "evidence": { "doc_id": "...", "page": 7, "quote": "…verbatim…" },
   "rationale": "one line, no inference" }]
```

**Stage 3 — Grounding verification (build this first, before any LLM).**
Pure Ruby, ~a day, and it is the feature:

```ruby
# Confirms an LLM-claimed quote actually appears on the cited page of the source.
# Anything unverifiable is downgraded to :unverified and can never render as ✓.
module PriorAuth
  class EvidenceVerifier
    def self.verify(evidence, document_text)
      page = document_text.page(evidence["doc_id"], evidence["page"])
      return :unverified if page.blank?
      needle = normalize(evidence["quote"])
      return :unverified if needle.length < 12          # too short to trust
      normalize(page).include?(needle) ? :verified : :unverified
      # v2: fuzzy (token-set ratio ≥ 0.9) to tolerate whitespace/OCR drift
    end

    def self.normalize(s) = s.to_s.downcase.gsub(/\s+/, " ").strip
  end
end
```

Building the harness before Stage 2 means every later stage is verifiable from day
one. Optional v2: an adversarial second pass ("is this snippet truly sufficient?")
using the judge-panel pattern.

**Stage 4 — Assemble.** Map verified results to `CriterionResult` rows.
`not_documented` / `unverified` → the **gap list** (the primary output). Aggregate
→ a drafted recommendation via `HosalivioBrain`, citing verified evidence + policy
sections. `AgentEvent` audit with model/source/doc-ids/token-counts (like
`polish_narrative`'s `change_set`). The "ESI #3 note was missing" case falls out
naturally: a `not_documented` verdict with no verified evidence.

**Stage 5 — Human review.** Reuse the intake-suggestions review-card pattern
(per-criterion accept/override) and the `icd_evidence` highlighting pattern
(quoted snippet deep-linked to source: `rails_blob_path(doc.file)` + `#page=N`).
Nothing final until the reviewer signs off.

## 5. Data model

Mirror the app's UUID + real-FK pattern. Per-review records are tenant-scoped;
**policies are not** (see the decision note).

> **Decision (implemented):** `coverage_policies` / `policy_criteria` are **global
> reference data** (no `acts_as_tenant`, no `agency_id`), like `Icd10Code` —
> Medicare LCDs/NCDs are shared, not per-tenant. This supersedes the original
> agency-scoped sketch below. Commercial, per-agency policies can add an
> **optional** `agency_id` later (null = shared Medicare). `PriorAuthReview`
> stays tenant-scoped.

```ruby
# Policy definitions — GLOBAL reference (no agency). Seed one real Medicare
# LCD/NCD by hand for slice 1 (db/seeds_prior_auth.rb seeds L34538).
create_table :coverage_policies, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.string  :payer,           null: false, default: "medicare"
  t.string  :source_type,     null: false, default: "lcd"           # "lcd" | "ncd"
  t.string  :document_id                                             # e.g. "L34538"
  t.string  :title,           null: false
  t.string  :url
  t.string  :procedure_hcpcs, array: true, null: false, default: [] # HCPCS this policy governs
  t.boolean :active,          null: false, default: true
  t.timestamps
end

# NB: PolicyCriterion pins self.table_name = "policy_criteria" (Rails would
# otherwise infer "policy_criterions").
create_table :policy_criteria, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.references :coverage_policy, type: :uuid, null: false, foreign_key: true
  t.integer :position, null: false, default: 0
  t.string  :label,       null: false                                  # "PPS ≤ 70%"
  t.text    :description
  t.string  :keywords, array: true, null: false, default: []           # retrieval anchors
  t.string  :evidence_type                                             # count | date_window | score | text
  t.timestamps
end

create_table :prior_auth_reviews, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.references :agency,          type: :uuid, null: false, foreign_key: true
  t.references :patient,         type: :uuid, null: false, foreign_key: true
  t.references :coverage_policy, type: :uuid, null: false, foreign_key: true
  t.references :reviewed_by,     type: :uuid, null: true,  foreign_key: { to_table: :users }
  t.string  :procedure_hcpcs                                           # public HCPCS only
  t.string  :provider_npi                                             # verified via Coding::Npi
  t.integer :status,          null: false, default: 0                 # draft / reviewed / signed (enum)
  t.integer :recommendation,  null: false, default: 0                 # pending / approve / gap / deny (enum)
  t.text    :recommendation_note                                     # encrypted (drafted summary)
  t.timestamps
end

create_table :criterion_results, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.references :prior_auth_review, type: :uuid, null: false, foreign_key: true
  t.references :policy_criterion,  type: :uuid, null: false, foreign_key: true
  t.integer :verdict,  null: false, default: 0   # met / unmet / not_documented / uncertain (enum)
  t.boolean :verified, null: false, default: false   # Stage-3 gate result
  t.jsonb   :evidence                             # { doc_id, page, quote } — encrypted at model layer
  t.text    :rationale
  t.timestamps
end

# Extracted, page-mapped source text. Encrypted (PHI).
create_table :document_texts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.references :agency,           type: :uuid, null: false, foreign_key: true
  t.references :patient_document, type: :uuid, null: false, foreign_key: true
  t.integer :status, null: false, default: 0     # extracted / needs_manual_review (enum)
  t.text    :pages_json                           # encrypts → [{ page:, text: }]
  t.timestamps
end
```

Signature reuse: sign-off through the existing polymorphic `Signature` model (as
the pre-admit eval and CC charting do), not a flat string.

## 6. Build order (each phase shippable / testable)

1. **Stage-3 `EvidenceVerifier`** + unit tests (pure Ruby, no LLM, no network).
2. **`DocumentText` extraction** (`pdf-reader`, digital-only; scans → manual-review flag).
3. **`CoveragePolicy` / `PolicyCriterion`** tables + seed one real LCD/NCD; generalize `Cms::CoverageApi` past the hospice filter.
4. **Stage-2 extractor** via `HosalivioBrain`, piped through the Stage-1 verifier; NPI + HCPCS + ICD validation reuse as-is.
5. **`PriorAuthReview` + `CriterionResult`** + the review/sign-off UI (review-card + evidence deep-links) + `AgentEvent` audit.

Rough shape: the validation / coverage / audit / drafting scaffolding is largely
reuse; the genuinely new build is (a) `DocumentText` extraction, (b) the criterion
extractor, and (c) the verification harness — a **multi-week new vertical**, not a
bolt-on.

## 7. Hard constraints & decisions

- **CPT is AMA-licensed** and cannot be freely redistributed. Slice 1 restricts to
  **HCPCS Level II (public)**; supporting CPT procedures needs a licensed dataset —
  decide before widening scope.
- **Commercial-payer policies are not in any free API** (per-payer PDF corpora).
  Slice 1 is **Medicare-only**, which the existing `Cms::CoverageApi` already serves.
- **Clinical-domain shift.** Users are utilization-review staff, not the hospice
  admission RN — a new product surface, new prompts, new roles.
- **Regulatory/liability.** Recommendations inform a payer decision; the human
  sign-off gate is mandatory, not optional.

## 8. Open questions

- ~~Which single LCD/NCD to seed first?~~ **Resolved:** L34538 (Hospice
  Determining Terminal Status) seeded as data in `db/seeds_prior_auth.rb` — real
  policy, real criteria; wording still needs SME verification vs. the live LCD.
- Fuzzy-match threshold for Stage 3 v2 (paraphrase tolerance vs. false-positive risk)?
- Enable OCR (Claude-vision extension of `HosalivioBrain`) in slice 2, or require
  digital submissions?
- Do we persist extracted `DocumentText` long-term (retrieval reuse) or treat it as
  ephemeral per review (tighter PHI posture)?
