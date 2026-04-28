class AddNarrativeRawToVisits < ActiveRecord::Migration[8.1]
  def change
    add_column :visits, :narrative_raw, :text
  end
end
