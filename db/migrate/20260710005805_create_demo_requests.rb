class CreateDemoRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :demo_requests, id: :uuid do |t|
      t.string :first_name
      t.string :last_name
      t.string :primary_ehr
      t.string :organization
      t.string :work_email
      t.string :phone
      t.string :referral_source
      t.string :referral_other
      t.string :ip_address
      t.string :user_agent

      t.timestamps
    end
  end
end
