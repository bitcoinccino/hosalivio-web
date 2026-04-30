class AddSignatureSupport < ActiveRecord::Migration[8.1]
  def change
    # Stamped when the user finishes drawing their signature in
    # the profile canvas; absence of this column tells the chart
    # UI to render a "Sign now" link instead of the registered-
    # signature checkbox.
    add_column :users, :signature_registered_at, :datetime

    # Polymorphic audit row written every time a registered (or
    # ad-hoc) signature is applied to anything in the chart —
    # PreAdmitEval certifications, Visit MD-routing, future late-
    # entry note sign-offs. CMS auditor query is a single
    # `where(signable_type: …, signable_id: …)` join.
    create_table :signatures, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true, index: true

      t.string  :signable_type, null: false
      t.uuid    :signable_id,   null: false

      t.string  :document_hash,        null: false
      t.string  :verification_method,  null: false   # e.g. "registered_signature", "drawn_inline", "typed_only"
      t.text    :intent_text,          null: false   # the exact "I certify..." copy the user accepted
      t.string  :ip_address
      t.string  :user_agent

      # Snapshot of the displayed name + the signature image blob
      # at signing time, so future name/avatar changes don't
      # rewrite the historical chart.
      t.string  :signed_name
      t.uuid    :signature_blob_id

      t.datetime :signed_at, null: false

      t.timestamps
    end

    add_index :signatures, [:signable_type, :signable_id]
    add_index :signatures, :signed_at
  end
end
