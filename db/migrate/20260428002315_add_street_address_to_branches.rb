class AddStreetAddressToBranches < ActiveRecord::Migration[8.1]
  def change
    add_column :branches, :address_line1, :string
    add_column :branches, :address_line2, :string
  end
end
