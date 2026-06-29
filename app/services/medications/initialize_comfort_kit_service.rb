module Medications
  # Builds the standing emergency "comfort kit" as a set of UNSAVED, draft
  # MedicationOrder suggestions for an intake nurse to review and an MD to
  # authorize. This is human-in-the-loop: nothing here prescribes anything —
  # the orders stay :draft (no authority) until an MD signs them active.
  #
  # The kit data lives here as a frozen constant and is the ONLY trusted source
  # of drug/dose/route. The form submits which item KEYS the nurse selected;
  # the controller rebuilds those items from this constant, so a tampered form
  # can never inject an arbitrary drug or dose.
  class InitializeComfortKitService
    # Transcribed and normalized from the physical hospice comfort-kit form.
    # `route` is the MedicationOrder enum symbol; the verbatim sig lives in
    # `instructions`. `frequency` + `prn_indication` are the structured fields.
    BASELINE_KIT_ITEMS = [
      { key: "acetaminophen_supp", name: "Acetaminophen Suppositories", quantity: "6",
        dose: "650 mg", route: :pr, frequency: "q4h PRN", prn_indication: "temp > 100°F",
        instructions: "Insert 1 suppository rectally q4h PRN temp > 100°F.", controlled: false },
      { key: "ativan", name: "Ativan (lorazepam) Tablets", quantity: "10",
        dose: "1 mg", route: :sl, frequency: "q4h PRN", prn_indication: "agitation",
        instructions: "1 tab PO or sublingual q4h PRN agitation.", controlled: true },
      { key: "atropine", name: "Atropine 1% Ophthalmic Solution", quantity: "1",
        dose: "1% ophthalmic solution", route: :sl, frequency: "q1h PRN", prn_indication: "terminal secretions",
        instructions: "2–3 gtts sublingual q1h PRN terminal secretions.", controlled: false },
      { key: "compazine_supp", name: "Compazine (prochlorperazine) Suppositories", quantity: "6",
        dose: "25 mg", route: :pr, frequency: "q6h PRN", prn_indication: "nausea",
        instructions: "Insert 1 suppository rectally q6h PRN nausea.", controlled: false },
      { key: "compazine_tab", name: "Compazine (prochlorperazine) Tablets", quantity: "6",
        dose: "10 mg", route: :po, frequency: "q4h PRN", prn_indication: "nausea",
        instructions: "1 tab PO q4h PRN nausea.", controlled: false },
      { key: "dulcolax_supp", name: "Dulcolax (bisacodyl) Suppositories", quantity: "6",
        dose: "10 mg", route: :pr, frequency: "q2–3 days PRN", prn_indication: "constipation",
        instructions: "1 suppository per rectum q2–3 days PRN constipation.", controlled: false },
      { key: "roxanol", name: "Roxanol (morphine concentrate) 30 mL bottle", quantity: "1",
        dose: "20 mg/mL", route: :po, frequency: "q2–4h PRN", prn_indication: "pain or respiratory distress",
        instructions: "0.25–0.5 mL (5–10 mg) PO/SL q2–4h PRN pain or respiratory distress.", controlled: true }
    ].freeze

    KEYS = BASELINE_KIT_ITEMS.map { |i| i[:key] }.freeze

    def self.item(key) = BASELINE_KIT_ITEMS.find { |i| i[:key] == key.to_s }

    def initialize(eval:, user:)
      @eval    = eval
      @patient = eval.patient
      @user    = user
      @agency  = eval.agency
    end

    # Unsaved draft orders for every kit item — used to render the review
    # checklist. `start_date` is intentionally left blank here (preview only);
    # it's stamped when the nurse actually saves a selection.
    def suggestions
      BASELINE_KIT_ITEMS.map { |item| build(item) }
    end

    # Build persisted-ready draft orders for the selected keys only. Pulls every
    # field from the trusted constant, ignoring anything the client sent except
    # the selection itself.
    def build_drafts(keys)
      selected = Array(keys).map(&:to_s) & KEYS
      selected.map { |key| build(self.class.item(key), start_date: Date.current) }
    end

    private

    def build(item, start_date: nil)
      MedicationOrder.new(
        agency:         @agency,
        patient:        @patient,
        pre_admit_eval: @eval,
        prescribed_by:  @patient.assigned_md || @user, # placeholder; the signing MD becomes prescriber on authorize
        drug_name:      item[:name],
        dose:           item[:dose],
        quantity:       item[:quantity],
        route:          item[:route].to_s,
        frequency:      item[:frequency],
        prn:            true,
        prn_indication: item[:prn_indication],
        instructions:   item[:instructions],
        controlled:     item[:controlled],
        comfort_kit:    true,
        status:         :draft,
        start_date:     start_date
      )
    end
  end
end
