class AddFriendlyNameToUsers < ActiveRecord::Migration[8.1]
  def change
    # Optional personal/friendly name shown as a secondary label next to the
    # role title (full_name). Lets an AI agent persona read as e.g.
    # "Admitting RN · Pascal" without the title being mistaken for a real human.
    add_column :users, :friendly_name, :string
  end
end
