class AddParentNoteIdToNotes < ActiveRecord::Migration[8.1]
  def change
    # Threading: a reply points at the root note it answers. NULL = top-level
    # message. One level deep only (enforced in the model) — replies can't
    # themselves be replied to. on_delete: :nullify so deleting a root note
    # doesn't cascade-delete its replies (they just become top-level).
    add_reference :notes, :parent_note, type: :uuid, null: true,
                  foreign_key: { to_table: :notes, on_delete: :nullify }
    add_index :notes, [ :parent_note_id, :created_at ]
  end
end
