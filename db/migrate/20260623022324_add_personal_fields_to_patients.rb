class AddPersonalFieldsToPatients < ActiveRecord::Migration[8.1]
  def change
    add_column :patients, :preferred_name, :string
    add_column :patients, :religion, :string
    add_column :patients, :veteran_status, :string
    add_column :patients, :caregiver_relationship, :string
  end
end
