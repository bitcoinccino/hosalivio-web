class CreateCcIntervalCharting < ActiveRecord::Migration[8.1]
  def change
    create_table :cc_interval_charts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :agency,  type: :uuid, null: false, foreign_key: true
      t.references :patient, type: :uuid, null: false, foreign_key: true
      t.references :visit,   type: :uuid, null: true,  foreign_key: true
      t.references :user,    type: :uuid, null: false, foreign_key: { to_table: :users }
      t.date    :date_of_shift, null: false
      t.time    :shift_start_time
      t.time    :shift_end_time
      t.boolean :facility_or_ha_shift,  null: false, default: false
      t.boolean :see_attached_addendum, null: false, default: false
      # PPE precautions
      t.boolean :universal_precautions,   null: false, default: false
      t.boolean :gown_or_apron,           null: false, default: false
      t.boolean :face_shield_or_goggles,  null: false, default: false
      t.boolean :mask,                    null: false, default: false
      t.boolean :n95_mask,                null: false, default: false
      t.boolean :contact_isolation,       null: false, default: false
      t.boolean :airborne_isolation,      null: false, default: false
      t.boolean :droplet_isolation,       null: false, default: false
      t.integer :status, null: false, default: 0  # draft / signed
      t.timestamps
    end

    create_table :cc_vitals_records, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :agency,           type: :uuid, null: false, foreign_key: true
      t.references :cc_interval_chart, type: :uuid, null: false, foreign_key: true
      t.time    :recorded_at, null: false
      t.decimal :temperature, precision: 4, scale: 1
      t.integer :pulse
      t.string  :blood_pressure
      t.integer :respiration
      t.string  :intake_details
      t.string  :output_diapers
      t.string  :bowel_movement
      t.timestamps
    end

    create_table :cc_poc_interventions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :agency,            type: :uuid, null: false, foreign_key: true
      t.references :cc_interval_chart,  type: :uuid, null: false, foreign_key: true
      t.references :medication_order,   type: :uuid, null: true,  foreign_key: true
      t.string  :ref_number
      t.string  :symptom
      t.string  :med_name_and_dose
      t.integer :med_source, null: false, default: 0  # nurse / caregiver
      t.time    :initial_time
      t.time    :post_time
      t.string  :initial_level
      t.string  :post_level
      t.text    :response_to_care
      t.jsonb   :non_verbal_indicators, null: false, default: {}
      t.timestamps
    end

    create_table :cc_controlled_substance_counts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :agency,            type: :uuid, null: false, foreign_key: true
      t.references :cc_interval_chart,  type: :uuid, null: false, foreign_key: true
      t.references :medication_order,   type: :uuid, null: true,  foreign_key: true
      t.string  :drug_name, null: false
      t.integer :count_at_start
      t.integer :count_at_end
      t.timestamps
    end
  end
end
