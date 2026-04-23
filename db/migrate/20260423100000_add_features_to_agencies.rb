class AddFeaturesToAgencies < ActiveRecord::Migration[8.1]
  def change
    add_column :agencies, :features, :jsonb, default: {}, null: false
    add_index  :agencies, :features, using: :gin
  end
end
