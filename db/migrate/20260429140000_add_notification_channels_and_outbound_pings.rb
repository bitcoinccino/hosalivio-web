class AddNotificationChannelsAndOutboundPings < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :notification_channels, :jsonb, default: {}, null: false

    create_table :outbound_pings, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :agency, type: :uuid, null: false, foreign_key: true
      t.references :user,   type: :uuid, null: false, foreign_key: true

      t.string   :kind, null: false       # crisis / urgent / handoff / recert / visit_starting / mention
      t.string   :preview, null: false    # PHI-free preview text shown in the channel ping
      t.jsonb    :payload, default: {}, null: false  # internal context (notification_id, note_id, source)

      t.string   :link_token, null: false # signed token used to authenticate the user when they tap the deeplink
      t.datetime :link_expires_at, null: false

      t.datetime :delivered_at            # nil until at least one channel has delivered
      t.jsonb    :delivered_channels, default: [], null: false  # ["telegram", "email"]
      t.text     :last_error              # last channel-side error message for ops debugging

      t.timestamps
    end

    add_index :outbound_pings, :link_token,                                unique: true
    add_index :outbound_pings, [:user_id, :delivered_at]
    add_index :outbound_pings, :created_at
    add_index :outbound_pings, :kind
  end
end
