module Api
  module V1
    class NotesController < BaseController
      def index
        notes = policy_scope(Note)
                  .where(patient_id: params[:patient_id])
                  .order(created_at: :desc).limit(100)
        render json: NoteSerializer.new(notes).serializable_hash
      end

      def show
        note = Note.find(params[:id])
        authorize note
        render json: NoteSerializer.new(note).serializable_hash
      end

      def create
        authorize Note
        note = Note.new(note_params.merge(
          agency:      Current.agency,
          patient_id:  params[:patient_id],
          author_role: Current.agent_id
        ))
        note.save!
        render json: NoteSerializer.new(note).serializable_hash, status: :created
      end

      # POST /api/v1/notes/:id/mark_read
      def mark_read
        note = Note.find(params[:id])
        authorize note, :update?
        note.mark_read!
        render json: NoteSerializer.new(note).serializable_hash
      end

      private

      def note_params
        params.require(:note).permit(:body, :source, :urgency, :author_user_id, :author_role)
      end
    end
  end
end
