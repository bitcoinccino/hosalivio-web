class CreateNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :notes, id: :uuid do |t|
      t.references :agency,  type: :uuid, foreign_key: true, null: false
      t.references :patient, type: :uuid, foreign_key: true, null: false

      # Who wrote it. If author_user is set, author_role should match their role;
      # if nil, the note came from an external surface (family web portal without login, agent ingest, etc).
      t.references :author_user, type: :uuid, foreign_key: { to_table: :users }, null: true
      t.string  :author_role, null: false   # family, rn, md, sw, chaplain, aide, pharmacy, dme, admissions, don, system, front_door_inbound

      t.text    :body, null: false          # encrypted at model layer — may contain PHI
      t.integer :source,  null: false, default: 0   # text=0, voice=1, system=2
      t.integer :urgency, null: false, default: 0   # normal=0, urgent=1, crisis=2

      t.datetime :read_at                    # when a clinician/agent acknowledged it

      t.timestamps
    end

    add_index :notes, [:agency_id, :patient_id, :created_at],
              name: "idx_notes_on_agency_patient_time"
    add_index :notes, [:agency_id, :urgency, :read_at],
              name: "idx_notes_on_agency_urgency_unread"
  end
end
