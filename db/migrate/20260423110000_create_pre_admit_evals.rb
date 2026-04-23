class CreatePreAdmitEvals < ActiveRecord::Migration[8.1]
  def change
    create_table :pre_admit_evals, id: :uuid do |t|
      t.references :agency,           type: :uuid, null: false, foreign_key: true
      t.references :patient,          type: :uuid, null: false, foreign_key: true
      t.references :visit,            type: :uuid, foreign_key: true
      t.references :evaluator,        type: :uuid, foreign_key: { to_table: :users }
      t.references :certified_by,     type: :uuid, foreign_key: { to_table: :users }

      # Evaluator metadata frozen at time of evaluation (license numbers rotate)
      t.string  :evaluator_name
      t.string  :evaluator_license
      t.string  :evaluator_role       # "rn", "np", etc.

      # Captured diagnosis + LCD signals pulled from raw_json for fast querying
      t.string  :primary_icd10
      t.string  :primary_icd10_description
      t.boolean :lcd_criteria_supported, default: false, null: false

      # Full extracted JSON — the source of truth the RN dictated.
      t.jsonb   :raw_json, default: {}, null: false

      # Workflow state. Matches the agent chain:
      #   draft             → Pascal still editing (unsaved or mid-visit)
      #   final             → Pascal submitted, awaiting MD certification
      #   certified         → MD (Esther) has signed CoE; ready for NOE filing
      #   noe_filed         → Insurance (Kendra) filed Medicare NOE within 5d
      #   revoked           → Rare: patient or family revoked election before NOE
      t.integer :status, null: false, default: 0

      t.datetime :evaluated_at
      t.datetime :finalized_at
      t.datetime :certified_at
      t.datetime :noe_filed_at
      t.datetime :noe_deadline_at        # evaluated_at + 5 days

      t.timestamps
    end

    add_index :pre_admit_evals, :status
    add_index :pre_admit_evals, :noe_deadline_at
    add_index :pre_admit_evals, :raw_json, using: :gin
  end
end
