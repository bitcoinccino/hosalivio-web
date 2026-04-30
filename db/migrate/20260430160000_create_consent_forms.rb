class CreateConsentForms < ActiveRecord::Migration[8.1]
  # Patient-side consent capture — Hospice Election, DNR, HIPAA
  # Acknowledgment, Plan of Care. Each row is a one-time fact: the
  # signer's drawn signature lives as an ActiveStorage attachment,
  # the signer identity (patient vs family/representative) lives on
  # the row, and the witnessing clinician's user_id is on
  # `witnessed_by`. The polymorphic `signatures` audit row hangs
  # off this record same as every other sign-off in the app.
  def change
    create_table :consent_forms, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :patient,      type: :uuid, null: false, foreign_key: true, index: true
      t.references :witnessed_by, type: :uuid, null: false, index: true
      t.references :agency,       type: :uuid, null: false, foreign_key: true, index: true

      t.string :kind,        null: false
      t.string :signer_role, null: false
      t.string :signer_name, null: false
      t.string :signer_relationship
      t.text   :signer_authority
      t.text   :form_content
      t.string :document_hash
      t.datetime :signed_at, null: false

      t.timestamps
    end
    add_index :consent_forms, [:patient_id, :kind]
    add_index :consent_forms, :signed_at
  end
end
