class CreatePartnerInvites < ActiveRecord::Migration[8.1]
  def change
    create_table :partner_invites, id: :uuid do |t|
      t.string   :token,        null: false
      t.string   :email                       # who the invite is for (optional)
      t.string   :agency_label                # sales reference — e.g. "Mercy Care, LLC"
      t.datetime :expires_at                   # nil = never expires
      t.datetime :used_at                      # set once consumed (one-time use)
      t.references :agency, type: :uuid, foreign_key: true   # the provisioned agency

      t.timestamps
    end

    add_index :partner_invites, :token, unique: true
  end
end
