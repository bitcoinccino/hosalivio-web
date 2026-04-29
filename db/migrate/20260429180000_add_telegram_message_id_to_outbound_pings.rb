class AddTelegramMessageIdToOutboundPings < ActiveRecord::Migration[8.1]
  def change
    add_column :outbound_pings, :telegram_message_id, :bigint
    add_index  :outbound_pings, :telegram_message_id, where: "telegram_message_id IS NOT NULL"
  end
end
