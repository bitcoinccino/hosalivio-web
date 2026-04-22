class AddServiceLocationToVisits < ActiveRecord::Migration[8.1]
  def change
    add_column :visits, :service_location, :integer, default: 0, null: false
    add_column :visits, :facility_name,    :string
    add_index  :visits, :service_location
  end
end
