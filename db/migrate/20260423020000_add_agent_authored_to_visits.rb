class AddAgentAuthoredToVisits < ActiveRecord::Migration[8.1]
  def change
    add_column :visits, :agent_authored, :boolean, null: false, default: false
    add_index  :visits, [ :agency_id, :agent_authored ]
  end
end
