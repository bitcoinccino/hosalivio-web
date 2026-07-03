class CreateDocumentTexts < ActiveRecord::Migration[8.1]
  def change
    create_table :document_texts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :agency,           type: :uuid, null: false, foreign_key: true
      t.references :patient_document, type: :uuid, null: false, foreign_key: true
      t.integer :status, null: false, default: 0   # extracted / needs_manual_review
      t.text    :pages_json                          # encrypted at model layer: [{ page:, text: }]
      t.timestamps
    end

    # One extracted-text record per document; re-extraction updates in place.
    add_index :document_texts, :patient_document_id, unique: true, name: "index_document_texts_on_document"
  end
end
