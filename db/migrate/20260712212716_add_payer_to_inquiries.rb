class AddPayerToInquiries < ActiveRecord::Migration[8.1]
  def change
    add_column :inquiries, :payer, :string
  end
end
