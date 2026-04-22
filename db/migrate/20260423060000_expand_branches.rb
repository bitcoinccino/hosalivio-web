class ExpandBranches < ActiveRecord::Migration[8.1]
  def change
    change_table :branches do |t|
      # Regulatory / compliance
      t.string :npi,                                   limit: 10   # CMS NPPES, 10 digits
      t.string :ccn                                                # Medicare CCN
      t.string :ein                                                # Tax ID
      t.string :state_license_number

      # Operational & routing
      t.jsonb  :service_area_zips,     default: [], null: false
      t.jsonb  :service_area_counties, default: [], null: false
      t.string :timezone,              default: "America/New_York", null: false
      t.string :triage_email
      t.string :after_hours_phone

      # Leadership (FKs to users)
      t.references :medical_director,     type: :uuid, foreign_key: { to_table: :users }
      t.references :director_of_nursing,  type: :uuid, foreign_key: { to_table: :users }
      t.references :clinical_supervisor,  type: :uuid, foreign_key: { to_table: :users }

      # Facility specifics
      t.integer :branch_type, null: false, default: 0
    end

    add_index :branches, :npi, unique: true, where: "npi IS NOT NULL"
    add_index :branches, :ccn, unique: true, where: "ccn IS NOT NULL"
    add_index :branches, :service_area_zips,     using: :gin
    add_index :branches, :service_area_counties, using: :gin
  end
end
