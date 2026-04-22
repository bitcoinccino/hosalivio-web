class CreateBranches < ActiveRecord::Migration[8.1]
  def change
    create_table :branches, id: :uuid do |t|
      t.references :agency,  type: :uuid, null: false, foreign_key: true
      t.references :manager, type: :uuid, foreign_key: { to_table: :users }
      t.string  :name, null: false
      t.string  :city
      t.string  :state
      t.string  :zip
      t.string  :phone
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    add_index :branches, [:agency_id, :name], unique: true

    add_reference :users,    :branch, type: :uuid, foreign_key: true
    add_reference :patients, :branch, type: :uuid, foreign_key: true
  end
end
