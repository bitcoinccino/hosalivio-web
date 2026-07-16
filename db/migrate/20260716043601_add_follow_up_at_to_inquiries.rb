class AddFollowUpAtToInquiries < ActiveRecord::Migration[8.1]
  def change
    add_column :inquiries, :follow_up_at, :datetime
  end
end
