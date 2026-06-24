class CreateZipCodes < ActiveRecord::Migration[8.1]
  def change
    # Offline ZIP -> city/state/county reference (~32k US ZIPs). Drives the
    # admissions-form address autofill and feeds Branch.route_for_zip so the
    # closest clinical team can be suggested without any external API.
    create_table :zip_codes, id: :uuid do |t|
      t.string :zip,    null: false
      t.string :city
      t.string :state
      t.string :county
      t.timestamps
    end

    add_index :zip_codes, :zip, unique: true
  end
end
