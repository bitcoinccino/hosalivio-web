# Continuous Care (CC) Interval Charting — Implementation Blueprint

Status: **planning** · Target branch: `feat/cc-interval-charting`

Goal: turn the paper "CC Interval (Shift) Charting" packet into an in-app,
audit-grade, structured charting feature for the **Visit RN, LPN, and CNA**
roles — with HosAlivio extracting the structured chart from dictation for a
human-in-the-loop review-and-sign.

The agent **behavior** is already in place: the Continuous Care protocol
(PIE, q2h, military time, no-911, role duties) is baked into the role agents
via `AgentBrain#continuous_care_block` (commit `d38c544`). That governs
*extraction quality*. This plan is the *structured target + form + sign-off*.

---

## 1. Phase 1 architecture — tables (UUID + tenant + real FKs + Signature)

Migration `ActiveRecord::Migration[8.1]`, mirroring the app's UUID pattern
(`id: :uuid, default: -> { "gen_random_uuid()" }`, `type: :uuid` on every
reference). Name/MRN come from `patient`; the signature comes from the existing
polymorphic `Signature` model — no flat strings.

```ruby
create_table :cc_interval_charts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.references :agency,  type: :uuid, null: false, foreign_key: true   # acts_as_tenant
  t.references :patient, type: :uuid, null: false, foreign_key: true   # name/MRN derived
  t.references :visit,   type: :uuid, null: true,  foreign_key: true   # the continuous visit
  t.references :user,    type: :uuid, null: false, foreign_key: { to_table: :users } # charting clinician
  t.date    :date_of_shift, null: false
  t.time    :shift_start_time          # "VIPU start / at bedside at"
  t.time    :shift_end_time            # "VIPU end / left residence at"
  t.boolean :facility_or_ha_shift, null: false, default: false
  t.boolean :see_attached_addendum, null: false, default: false
  # PPE matrix
  t.boolean :universal_precautions, :gown_or_apron, :face_shield_or_goggles,
            :mask, :n95_mask, :contact_isolation, :airborne_isolation,
            :droplet_isolation, null: false, default: false
  t.integer :status, null: false, default: 0   # draft / signed (enum)
  t.timestamps
end

create_table :cc_vitals_records, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.references :cc_interval_chart, type: :uuid, null: false, foreign_key: true
  t.time :recorded_at, null: false
  t.decimal :temperature, precision: 4, scale: 1
  t.integer :pulse; t.string :blood_pressure; t.integer :respiration
  t.string :intake_details, :output_diapers, :bowel_movement
  t.timestamps
end

create_table :cc_poc_interventions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.references :cc_interval_chart, type: :uuid, null: false, foreign_key: true
  t.references :medication_order,  type: :uuid, null: true, foreign_key: true  # cross-ref MAR
  t.string  :ref_number, :symptom, :med_name_and_dose
  t.integer :med_source, null: false, default: 0   # nurse / caregiver (enum)
  t.time    :initial_time, :post_time
  t.string  :initial_level, :post_level
  t.text    :response_to_care
  t.jsonb   :non_verbal_indicators, null: false, default: {}  # breathing/vocal/facial/body/consolability
  t.timestamps
end

create_table :cc_controlled_substance_counts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
  t.references :cc_interval_chart, type: :uuid, null: false, foreign_key: true
  t.references :medication_order,  type: :uuid, null: true, foreign_key: true  # the active narcotic order
  t.string  :drug_name, null: false
  t.integer :count_at_start, :count_at_end
  t.timestamps
end
```

Models — tenant on the parent, children scoped through it; `Signature` is
polymorphic (same as visits/evals):

```ruby
class CcIntervalChart < ApplicationRecord
  acts_as_tenant :agency
  belongs_to :agency; belongs_to :patient; belongs_to :user
  belongs_to :visit, optional: true
  has_many :cc_vitals_records, dependent: :destroy
  has_many :cc_poc_interventions, dependent: :destroy
  has_many :cc_controlled_substance_counts, dependent: :destroy
  has_many :signatures, as: :signable, dependent: :destroy   # reuse audit-grade sign-off
  enum :status, { draft: 0, signed: 1 }, prefix: true
  accepts_nested_attributes_for :cc_vitals_records, :cc_poc_interventions,
                                :cc_controlled_substance_counts, allow_destroy: true
  validates :patient, :user, :date_of_shift, presence: true
end

class CcPocIntervention < ApplicationRecord
  belongs_to :cc_interval_chart
  belongs_to :medication_order, optional: true
  enum :med_source, { nurse: 0, caregiver: 1 }, prefix: true
  VALID_LEVELS = (%w[None Mild Moderate Severe] + (0..10).map(&:to_s)).freeze
  validates :initial_level, :post_level,
            inclusion: { in: VALID_LEVELS, allow_blank: true,
                         message: "must be 0-10, None, Mild, Moderate, or Severe" }
  # caregiver-administered → forced phrase "Patient or Caregiver Indicated They Provided"
end
```

Dropped vs the reference spec (derive instead of store): `patient_name`,
`mr_number`, `clinician_signature_name`, `clinician_discipline`,
`signature_date` — from `patient`, the `Signature`, and the signer's role.

---

## 2. Form-component mapping (cross-reference existing constraints)

- **`cc_vitals_records`** — reuse the existing Visit vitals/pain bounds (the
  app already validates `pain_score 0..10`); validate `blood_pressure` as
  "sys/dia".
- **`cc_poc_interventions`** — `med_source` enum drives the rule: caregiver →
  forced phrase "Patient or Caregiver Indicated They Provided"; nurse →
  med name + dose + response required. `initial/post_level` validated against
  `VALID_LEVELS`. `non_verbal_indicators` jsonb captures the
  breathing/vocal/facial/body/consolability cheat-sheet (structured, not free
  text). Optional `medication_order_id` ties the intervention to the patient's
  real order.
- **`cc_controlled_substance_counts`** — do NOT duplicate the MAR. Each count
  row optionally links to the patient's active controlled `MedicationOrder`;
  the *count* is shift reconciliation (start/end), while actual doses given in
  the shift write to the existing **`MedicationLog`** (one MAR source of truth).
  HosAlivio can flag `start − administered ≠ end`.

---

## 3. Design-system compliance

Translate the reference's blue/gray Tailwind to the app tokens + existing form
wrappers. Canonical input class (from `patient_families/_form.html.erb`):

```
w-full px-3 py-2 rounded-lg border border-[#D9D5CD] bg-[#FBF9F5]
focus:bg-white focus:border-[#D97757] focus:outline-none text-[14px]
```

- Section headers: cream/orange, not `bg-gray-700` / `bg-blue-600`.
- Submit: orange pill `bg-[#D97757] hover:bg-[#c46a4b]`.
- Vitals matrix + interventions tables keep the grid but use `border-[#EFECE6]`,
  `text-[#1D1C1A]`, `text-[#6B665F]`.
- The yellow key/guide accordions are fine (informational), warm-tinted.

---

## 4. Enums & foundations — exact locations

- **`app/models/visit.rb:16`** `discipline` enum → add `lpn: 6` (after
  `don: 5`). Integer enum — no migration needed.
- **`app/models/visit.rb:20`** `visit_type` enum → add `continuous: 8` (after
  `inquiry: 7`); add `"continuous" => "Continuous Care"` to
  `VISIT_TYPE_LABELS` (~:41) and a bucket in `VISIT_TYPE_CATEGORIES` (~:30).
- `Role::ROLE_NAMES` already includes `lpn`; `patients.assigned_lpn` already
  exists (prior commit). No change.
- New: `CcIntervalChartsController`, routes, the `_form` partial, the four
  models.

---

## 5. Agent-brain integration (human-in-the-loop hook)

- Add a structured action to `app/services/agent_brain.rb` — `write_cc_interval`
  — whose JSON payload **is shaped as the nested_attributes hash**:

  ```json
  { "date_of_shift": "...", "shift_start_time": "1400",
    "ppe": { "mask": true, "universal_precautions": true },
    "cc_vitals_records_attributes": [ { "recorded_at": "1400", "pulse": 88 } ],
    "cc_poc_interventions_attributes": [ { "symptom": "pain", "initial_level": "7",
        "med_source": "nurse", "post_level": "3", "response_to_care": "Effective" } ],
    "cc_controlled_substance_counts_attributes": [ { "drug_name": "morphine",
        "count_at_start": 20, "count_at_end": 18 } ] }
  ```

- `AgentBrain#continuous_care_block` (already shipped, `d38c544`) governs
  extraction quality (PIE, military time, valid levels, HA-vs-nurse phrasing),
  so the agent emits compliant fields.
- **Flow:** clinician dictates → `agent_brain` returns the payload →
  `CcIntervalChartsController#new` builds an **unsaved** `CcIntervalChart` with
  nested records → renders the `_form` **prefilled** → clinician reviews/edits →
  submit saves as `status: :draft` → **sign** creates a `Signature` and flips
  to `:signed`. Nothing commits without the human sign-off — same gate as
  visits/evals (human-in-the-loop).
- Reuse the existing JSON parse/sanitize path; add a CC sanitizer (normalize
  military time, enforce the `VALID_LEVELS` inclusion list, drop ungrounded
  fields per the documentation-discipline rules).

---

## Refinements (from the finalized plan)

**Codebase corrections to the finalized plan:**
- Discipline is **`Visit#discipline`**, not `User#discipline` (there is no
  discipline column on User; a user's discipline = `user.role_names`). Extend
  `Visit#discipline` with `lpn`.
- **CNA = the existing `aide` role** — do NOT add a separate `cna`. The CNA
  medication boundary keys off the charting user's role.

**CNA medication boundary (model validation, keyed off role, not a User enum):**
```ruby
# in CcPocIntervention / CcControlledSubstanceCount
validate :cna_cannot_document_meds
def cna_cannot_document_meds
  charting_user = cc_interval_chart&.user
  return unless charting_user&.role_names&.include?("aide")
  if med_name_and_dose.present?
    errors.add(:base, "CNAs cannot document medications — notify the LPN or RN.")
  end
end
```

**Phase 2 — named Stimulus controllers:**
- `cc-form-defaults` — toggling `facility_or_ha_shift` / `see_attached_addendum`
  dims/hides the now-optional validation targets.
- `medication-source` — when a row's source is caregiver/HA, set the response
  field read-only and auto-insert the required phrase
  "Patient or Caregiver Indicated They Provided".
- Standard nested-fields "add row" buttons for `poc_interventions` /
  `vitals_records` / `controlled_substance_counts`.

**Phase 3 — extraction example + highlighted review UX:**
Dictation: *"Arrived at 0800. BP 120/80, pulse 72. Patient moaning and
grimacing intensely. Administered liquid morphine 5mg at 0815. Reassessed at
0900, grimacing resolved, patient sleeping."* maps to:
```json
{ "cc_vitals_records_attributes": [
    { "recorded_at": "0800", "blood_pressure": "120/80", "pulse": 72 } ],
  "cc_poc_interventions_attributes": [
    { "symptom": "moaning and grimacing intensely", "initial_level": "Severe",
      "med_name_and_dose": "liquid morphine 5mg", "med_source": "nurse",
      "initial_time": "0815", "post_time": "0900", "post_level": "None",
      "response_to_care": "Effective",
      "non_verbal_indicators": { "facial": "grimacing", "vocal": "moaning" } } ] }
```
Review UX: an **AI processing drawer** takes the dictation, submits async, and
**prefills** the Phase-2 form. AI-populated fields are subtly tinted (cream /
soft yellow) so the clinician can scan what to verify; they correct, tick the
verification box, and **electronically sign** (`Signature`) to commit — nothing
reaches the EHR tables unsigned.

## Phased roadmap

1. **Foundations + data** — `continuous` visit_type, `lpn` discipline,
   `CcIntervalChart` + 3 nested tables (UUID/tenant/patient+visit FK), models +
   validations.
2. **Manual form** — the template restyled to the design system, nested
   attributes + Stimulus (med-source toggle, level validation, non-verbal
   helper), sign via `Signature`.
3. **AI mapping** — `write_cc_interval` extraction → prefilled form → review →
   sign.

## Notes
- Build on `feat/cc-interval-charting` (separate from PR #51, which is
  chat/roles). Rebase onto `main` once #51 merges.
- Reuses, not reinvents: `Signature` (sign-off), `MedicationOrder`/
  `MedicationLog` (MAR), `AgentBrain` extraction pattern, the role CC protocol.
