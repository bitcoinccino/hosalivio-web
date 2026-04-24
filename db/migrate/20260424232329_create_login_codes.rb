class CreateLoginCodes < ActiveRecord::Migration[8.1]
  def change
    create_table :login_codes, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string   :code_digest, null: false
      t.datetime :expires_at,  null: false
      t.datetime :consumed_at
      t.string   :ip

      t.timestamps
    end
    add_index :login_codes, :code_digest
    add_index :login_codes, :expires_at
  end
end
