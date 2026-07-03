class AddIntakeSuggestionsToVisits < ActiveRecord::Migration[8.1]
  def change
    add_column :visits, :intake_suggestions, :text
  end
end
