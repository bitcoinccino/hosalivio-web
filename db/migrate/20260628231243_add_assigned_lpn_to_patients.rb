class AddAssignedLpnToPatients < ActiveRecord::Migration[8.1]
  # The patient's Support Nurse (LPN), shown on the care-team roster.
  # Nullable — not every patient has an LPN assigned.
  def change
    add_column :patients, :assigned_lpn_id, :uuid
    add_index  :patients, :assigned_lpn_id
    add_foreign_key :patients, :users, column: :assigned_lpn_id
  end
end
