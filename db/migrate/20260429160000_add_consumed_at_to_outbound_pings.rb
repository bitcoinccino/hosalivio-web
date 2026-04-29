class AddConsumedAtToOutboundPings < ActiveRecord::Migration[8.1]
  def change
    add_column :outbound_pings, :consumed_at, :datetime
    add_index  :outbound_pings, :consumed_at, where: "consumed_at IS NOT NULL"
  end
end
