class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications, id: :uuid do |t|
      t.references :agency, type: :uuid, foreign_key: true, null: false
      t.references :user,   type: :uuid, foreign_key: true, null: false

      t.string  :kind,  null: false             # visit_reminder_24h, inquiry_received, etc.
      t.string  :title, null: false
      t.text    :body

      # Polymorphic pointer back to the thing the notification is about
      t.string :linked_type
      t.uuid   :linked_id

      t.datetime :read_at
      t.datetime :delivered_at

      t.timestamps
    end

    add_index :notifications, [ :agency_id, :user_id, :read_at ], name: "idx_notifications_inbox"
    add_index :notifications, [ :linked_type, :linked_id ]
  end
end
