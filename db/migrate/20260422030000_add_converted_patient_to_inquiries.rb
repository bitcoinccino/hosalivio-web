class AddConvertedPatientToInquiries < ActiveRecord::Migration[8.1]
  def change
    add_reference :inquiries, :converted_patient,
                  type: :uuid,
                  foreign_key: { to_table: :patients },
                  null: true
  end
end
