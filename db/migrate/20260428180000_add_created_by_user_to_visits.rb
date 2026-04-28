class AddCreatedByUserToVisits < ActiveRecord::Migration[8.1]
  def change
    add_reference :visits, :created_by_user, type: :uuid, foreign_key: { to_table: :users }, null: true
  end
end
