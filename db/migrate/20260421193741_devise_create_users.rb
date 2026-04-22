# frozen_string_literal: true

class DeviseCreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :uuid do |t|
      # Tenant scope — system admins are NULL; everyone else belongs to one agency.
      t.references :agency, type: :uuid, foreign_key: true, null: true

      # Devise — database_authenticatable
      t.string :email,              null: false, default: ""
      t.string :encrypted_password, null: false, default: ""

      # Devise — recoverable
      t.string   :reset_password_token
      t.datetime :reset_password_sent_at

      # Devise — rememberable
      t.datetime :remember_created_at

      # HosAlivio profile
      t.string  :full_name,    null: false
      t.string  :timezone,     null: false, default: "America/New_York"
      t.boolean :active,       null: false, default: true

      # Family portal access — when true, user is gated to a single patient
      t.boolean :family_access, null: false, default: false
      # patient_id FK is added later by CreateHospiceSchema (patients table doesn't exist yet)

      t.timestamps null: false
    end

    add_index :users, :email,                unique: true
    add_index :users, :reset_password_token, unique: true
  end
end
