class AddPreferredCallWindowToInquiries < ActiveRecord::Migration[8.1]
  def change
    add_column :inquiries, :preferred_date, :date
    add_column :inquiries, :preferred_slot, :string
  end
end
