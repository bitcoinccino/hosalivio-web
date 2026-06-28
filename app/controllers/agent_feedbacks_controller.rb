# Dashboard for curators (admin / DON) to review AI feedback signals.
# Shows thumbs-down rows with reasons + free text grouped by audit_kind
# so prompt fixes can be triaged. The thumbs-up tally + per-week ratio
# is the agent-quality KPI; thumbs-down rows are the work queue.
class AgentFeedbacksController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_curator!

  PRIVILEGED_ROLES = %w[admin don].freeze

  def show
    ActsAsTenant.with_tenant(current_user.agency) do
      base = Note.where.not(feedback_score: nil).order(feedback_at: :desc)
      @thumbs_down = base.where(feedback_score: -1).limit(50).to_a
      @thumbs_up_count   = base.where(feedback_score:  1).count
      @thumbs_down_count = base.where(feedback_score: -1).count
      @total_ai_notes    = Note.where(author_role: %w[admissions]).count
      @last_week_ratio   = ratio_for(7.days.ago)
      @last_30d_ratio    = ratio_for(30.days.ago)
      @reason_breakdown  = breakdown_reasons
    end
  end

  private

  def authorize_curator!
    return if (current_user.role_names & PRIVILEGED_ROLES).any?
    redirect_to dashboard_path, alert: "Only admins / DON can review AI feedback."
  end

  def ratio_for(since)
    scored = Note.where("feedback_at > ?", since).where.not(feedback_score: nil).count
    return nil if scored.zero?
    ups = Note.where("feedback_at > ?", since).where(feedback_score: 1).count
    (ups.to_f / scored * 100).round(1)
  end

  def breakdown_reasons
    counts = Hash.new(0)
    Note.where(feedback_score: -1).pluck(:feedback_reasons).each do |arr|
      Array(arr).each { |r| counts[r] += 1 }
    end
    counts.sort_by { |_, n| -n }
  end
end
