class AddAssignedVisitRnToPatients < ActiveRecord::Migration[8.1]
  # The Visit / Primary Nurse who carries ongoing care, distinct from the
  # admission RN (assigned_rn) who only admits. Nullable: ongoing routing
  # falls back to assigned_rn until a separate visit nurse is assigned.
  def change
    add_column :patients, :assigned_visit_rn_id, :uuid
    add_index  :patients, :assigned_visit_rn_id
    add_foreign_key :patients, :users, column: :assigned_visit_rn_id
  end
end
