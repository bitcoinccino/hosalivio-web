class AddParentToChannelMessages < ActiveRecord::Migration[8.1]
  def change
    add_reference :channel_messages, :parent, type: :uuid, null: true,
                  foreign_key: { to_table: :channel_messages }, index: true
  end
end
