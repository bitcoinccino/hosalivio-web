class AddFeedbackColumnsToNotes < ActiveRecord::Migration[8.1]
  def change
    add_column    :notes, :feedback_score,   :integer
    add_column    :notes, :feedback_reasons, :jsonb, default: [], null: false
    add_column    :notes, :feedback_notes,   :text
    add_reference :notes, :feedback_by,      type: :uuid, foreign_key: { to_table: :users }, null: true
    add_column    :notes, :feedback_at,      :datetime
    add_index     :notes, :feedback_score,   where: "feedback_score IS NOT NULL"
  end
end
