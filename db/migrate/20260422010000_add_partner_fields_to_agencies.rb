class AddPartnerFieldsToAgencies < ActiveRecord::Migration[8.1]
  def change
    change_table :agencies, bulk: true do |t|
      t.text    :bio
      t.jsonb   :specialties,         null: false, default: []
      t.jsonb   :insurance_accepted,  null: false, default: []
      t.jsonb   :languages,           null: false, default: [ "en" ]
      t.jsonb   :service_area_zips,   null: false, default: []
      t.string  :hero_color,          null: false, default: "#D97757"
      t.string  :emoji,               null: false, default: "🩺"
      t.boolean :is_partner,          null: false, default: false
      t.boolean :accepting_referrals, null: false, default: true
      t.integer :response_sla_hours,  null: false, default: 24
    end

    add_index :agencies, :is_partner
    add_index :agencies, :accepting_referrals
  end
end
