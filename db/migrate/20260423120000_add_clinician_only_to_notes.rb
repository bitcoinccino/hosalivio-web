class AddClinicianOnlyToNotes < ActiveRecord::Migration[8.1]
  def change
    add_column :notes, :clinician_only, :boolean, default: false, null: false
    add_index  :notes, :clinician_only
  end
end
