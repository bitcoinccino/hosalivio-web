class HosalivioTriageJob < ApplicationJob
  queue_as :default

  def perform(note_id)
    note = Note.unscoped.find_by(id: note_id)
    return if note.nil?
    return unless note.author_role == "family" && note.read_at.nil?

    ActsAsTenant.with_tenant(note.agency) do
      HosalivioTriager.new(note).triage!
    end
  end
end
