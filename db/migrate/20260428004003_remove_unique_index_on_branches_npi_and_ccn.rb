class RemoveUniqueIndexOnBranchesNpiAndCcn < ActiveRecord::Migration[8.1]
  # Branches in the same agency commonly share the corporate NPI/CCN
  # unless a specific location is separately enrolled with Medicare.
  # Replace the global unique partial indexes with non-unique lookup
  # indexes so the form stops rejecting legitimate duplicates.
  def change
    remove_index :branches, :npi, if_exists: true
    remove_index :branches, :ccn, if_exists: true
    add_index :branches, :npi unless index_exists?(:branches, :npi)
    add_index :branches, :ccn unless index_exists?(:branches, :ccn)
  end
end
