class AddAcknowledgedAtToAgentEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_events,    :acknowledged_at,         :datetime
    add_reference :agent_events, :acknowledged_by_user, type: :uuid, foreign_key: { to_table: :users }, null: true
    add_index :agent_events,    :acknowledged_at, where: "acknowledged_at IS NOT NULL"
  end
end
