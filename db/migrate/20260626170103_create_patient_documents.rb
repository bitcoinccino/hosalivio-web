class CreatePatientDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :patient_documents, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :agency,      type: :uuid, null: false, foreign_key: true
      t.references :patient,     type: :uuid, null: false, foreign_key: true
      t.references :uploaded_by, type: :uuid, null: true,  foreign_key: { to_table: :users }
      t.string :title, null: false
      t.string :kind
      t.timestamps
    end
  end
end
