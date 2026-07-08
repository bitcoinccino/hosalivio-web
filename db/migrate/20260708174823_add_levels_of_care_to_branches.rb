class AddLevelsOfCareToBranches < ActiveRecord::Migration[8.1]
  def change
    add_column :branches, :levels_of_care, :jsonb, default: [], null: false
    add_index  :branches, :levels_of_care, using: :gin
  end
end
