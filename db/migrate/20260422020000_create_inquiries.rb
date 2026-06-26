class CreateInquiries < ActiveRecord::Migration[8.1]
  def change
    create_table :inquiries, id: :uuid do |t|
      # Which partner this inquiry is addressed to. Nullable agency_id is
      # never expected; general inquiries still pick a default agency but
      # carry is_general: true for UI labeling.
      t.references :agency, type: :uuid, foreign_key: true, null: false
      t.boolean    :is_general, null: false, default: false

      # Who / how the inquirer reached us
      t.string :first_name      # encrypted at model layer
      t.string :contact         # encrypted at model layer (phone OR email, free-form)
      t.string :zip             # encrypted (deterministic) so we can still prefix-search
      t.text   :question        # encrypted (their free-form message, if any)
      t.string :source_prompt, null: false, default: "capture"  # partner_card | ask_anything | speak | near | capture

      # Routing + lifecycle
      t.string :routed_to_role, null: false, default: "admissions"
      t.references :claimed_by, type: :uuid, foreign_key: { to_table: :users }, null: true
      t.datetime :claimed_at
      t.datetime :contacted_at
      t.datetime :converted_at
      t.integer :status, null: false, default: 0   # new=0 claimed=1 contacted=2 converted=3 dismissed=4

      t.timestamps
    end

    add_index :inquiries, [ :agency_id, :status ]
    add_index :inquiries, [ :status, :created_at ]
  end
end
