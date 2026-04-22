class AddClinicianFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users do |t|
      t.string  :phone_number
      t.string  :npi, limit: 10             # only meaningful for MDs / billable practitioners
      t.string  :license_number
      t.date    :license_expires_on
      t.integer :employment_type, default: 0, null: false # enum
      t.integer :max_caseload,    default: 15, null: false
      t.boolean :on_call,         default: false, null: false
      t.jsonb   :service_zips,    default: [], null: false # nurse covers a subset of branch's ZIPs
    end

    add_index :users, :license_expires_on
    add_index :users, :on_call
    add_index :users, :service_zips, using: :gin
  end
end
