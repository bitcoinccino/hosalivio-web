class AddTranscriptSegmentsToVisits < ActiveRecord::Migration[8.1]
  def change
    # Per-turn audio timing captured from Deepgram during recording, so the
    # transcript sidebar can seek the bedside audio to a specific speaker turn.
    # Shape: [{ "speaker" => "Patient", "start" => 12.3, "end" => 18.7 }, ...].
    add_column :visits, :transcript_segments, :jsonb, null: false, default: []
  end
end
