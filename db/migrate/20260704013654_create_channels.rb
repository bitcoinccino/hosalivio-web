class CreateChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :channels, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :agency, type: :uuid, null: false, foreign_key: true  # acts_as_tenant
      t.string  :name,        null: false
      t.string  :slug,        null: false
      t.string  :description
      t.string  :post_roles,  array: true, null: false, default: []      # [] = any staff may post
      t.boolean :system,      null: false, default: false                # seeded default, undeletable
      t.integer :position,    null: false, default: 0
      t.timestamps
    end
    add_index :channels, [ :agency_id, :slug ], unique: true

    create_table :channel_messages, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :agency,  type: :uuid, null: false, foreign_key: true
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.references :user,    type: :uuid, null: false, foreign_key: true
      t.text :body, null: false
      t.timestamps
    end
    add_index :channel_messages, [ :channel_id, :created_at ]
  end
end
