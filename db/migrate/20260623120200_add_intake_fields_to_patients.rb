class AddIntakeFieldsToPatients < ActiveRecord::Migration[8.1]
  def change
    add_column :patients, :pronouns, :string
    add_column :patients, :interpreter_needed, :boolean, default: false, null: false
  end
end
