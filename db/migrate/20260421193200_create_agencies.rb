class CreateAgencies < ActiveRecord::Migration[8.1]
  def change
    create_table :agencies, id: :uuid do |t|
      t.string  :name,                      null: false
      t.string  :slug,                      null: false           # used as MRN prefix, e.g. "HOS"
      t.string  :address_line1
      t.string  :address_line2
      t.string  :city
      t.string  :state
      t.string  :zip
      t.string  :phone
      t.string  :npi                                              # 10-digit National Provider ID
      t.string  :medicare_provider_number
      t.integer :billing_tier,              null: false, default: 0   # enum: starter=0, pro=1, enterprise=2
      t.boolean :active,                    null: false, default: true

      t.timestamps
    end

    add_index :agencies, :slug, unique: true
    add_index :agencies, :npi,  unique: true, where: "npi IS NOT NULL"
    add_index :agencies, :medicare_provider_number, unique: true,
              where: "medicare_provider_number IS NOT NULL",
              name: "idx_agencies_on_medicare_number"
  end
end
