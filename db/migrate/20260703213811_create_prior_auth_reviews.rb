class CreatePriorAuthReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :prior_auth_reviews, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :agency,          type: :uuid, null: false, foreign_key: true   # acts_as_tenant
      t.references :patient,         type: :uuid, null: false, foreign_key: true
      t.references :coverage_policy, type: :uuid, null: false, foreign_key: true
      t.references :reviewed_by,     type: :uuid, null: true,  foreign_key: { to_table: :users }
      t.string  :procedure_hcpcs                                  # public HCPCS only
      t.string  :provider_npi                                     # validated via Coding::Npi
      t.integer :status,         null: false, default: 0          # draft / reviewed / signed
      t.integer :recommendation, null: false, default: 0          # pending / approve / gap / deny
      t.text    :recommendation_note                              # encrypted (drafted summary)
      t.timestamps
    end

    # Criterion-level results (line items scoped through their review, which is
    # tenant-scoped). evidence_json is encrypted at the model layer.
    create_table :criterion_results, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :prior_auth_review, type: :uuid, null: false, foreign_key: true
      # "policy_criterion" pluralizes wrong; the table is policy_criteria.
      t.references :policy_criterion,  type: :uuid, null: false, foreign_key: { to_table: :policy_criteria }
      t.integer :verdict,  null: false, default: 0                # met / unmet / not_documented / uncertain
      t.boolean :verified, null: false, default: false           # Stage-3 gate result
      t.text    :evidence_json                                    # encrypted: { doc_id, page, quote }
      t.text    :rationale
      t.timestamps
    end
  end
end
