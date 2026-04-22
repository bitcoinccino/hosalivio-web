class CreateIcd10Explanations < ActiveRecord::Migration[8.1]
  def change
    create_table :icd10_explanations, id: :uuid do |t|
      t.string :code,               null: false
      t.string :simple_description, null: false
      t.string :hospice_context
      t.string :category  # optional grouping: cancer, cardiac, pulmonary, neuro, renal, infectious, debility
      t.timestamps
    end
    add_index :icd10_explanations, :code, unique: true
  end
end
