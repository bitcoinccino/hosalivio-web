# Captures clinician thumbs-up / thumbs-down feedback on AI-authored
# Notes (HosAlivio acks, family-facing AI replies, triage decisions).
# Stores the score + structured reasons + free text + author + time.
# Feedback is NEVER auto-fed back into prompts; it's a curated corpus
# for offline prompt improvement and a metrics dashboard.
class NoteFeedbacksController < ApplicationController
  before_action :authenticate_user!
  before_action :set_note

  def create
    score = params[:score].to_i
    return render(json: { error: "invalid_score" }, status: :unprocessable_entity) unless [-1, 0, 1].include?(score)

    reasons = Array(params[:reasons]).map(&:to_s) & Note::FEEDBACK_REASONS
    notes   = params[:notes].to_s.strip[0, 1_000].presence

    @note.update!(
      feedback_score:   score,
      feedback_reasons: reasons,
      feedback_notes:   notes,
      feedback_by:      current_user,
      feedback_at:      Time.current
    )

    AgentEvent.create!(
      agency:      @note.agency,
      agent_id:    "feedback",
      action:      score.positive? ? "thumbs_up" : (score.negative? ? "thumbs_down" : "thumbs_clear"),
      subject:     @note,
      happened_at: Time.current,
      change_set: {
        feedback_by: current_user.id,
        score:       score,
        reasons:     reasons,
        had_notes:   notes.present?,
        author_role: @note.author_role,
        audit_kind:  @note.audit_kind.to_s
      }
    )

    render json: { ok: true, score: score }
  end

  private

  def set_note
    ActsAsTenant.with_tenant(current_user.agency) do
      @note = Note.find(params[:note_id])
    end
    head :forbidden if @note.agency_id != current_user.agency_id
  end
end
