class AddPartnerProfileFieldsToAgencies < ActiveRecord::Migration[8.1]
  def change
    change_table :agencies do |t|
      t.string  :dba_name
      t.string  :administrator_name

      t.integer :accreditation_body
      t.integer :mac_region

      t.integer :emr_system
      t.integer :pharmacy_partner
      t.integer :dme_partner

      t.jsonb :pricing_tiers, default: {}, null: false
      t.string :after_hours_instructions
    end
  end
end
