class CreateCoveragePolicies < ActiveRecord::Migration[8.1]
  def change
    # Global reference data (like icd10_codes) — Medicare LCDs/NCDs are shared,
    # not per-tenant. Commercial (agency-specific) policies can add an optional
    # agency_id later.
    create_table :coverage_policies, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string  :payer,           null: false, default: "medicare"
      t.string  :source_type,     null: false, default: "lcd"   # lcd / ncd
      t.string  :document_id                                     # "L34538"
      t.string  :title,           null: false
      t.string  :url
      t.string  :procedure_hcpcs, array: true, null: false, default: []  # HCPCS this policy governs
      t.boolean :active,          null: false, default: true
      t.timestamps
    end
    add_index :coverage_policies, :document_id

    create_table :policy_criteria, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :coverage_policy, type: :uuid, null: false, foreign_key: true
      t.integer :position, null: false, default: 0
      t.string  :label,    null: false                           # "PPS <= 70%"
      t.text    :description
      t.string  :keywords, array: true, null: false, default: [] # retrieval anchors
      t.string  :evidence_type                                   # count / date_window / score / text
      t.timestamps
    end
    add_index :policy_criteria, [ :coverage_policy_id, :position ]
  end
end
