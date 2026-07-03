# Stage 5: the reviewer opens a grounded prior-auth determination and signs off
# (see docs/prior-auth-slice.md). Read-only surfacing of the pipeline output plus
# a human sign-off — nothing here decides on its own.
class PriorAuthReviewsController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_reviewer!
  before_action :set_review

  # Utilization-review-ish roles. No family; agency is enforced by the tenant scope.
  REVIEWER_ROLES = %w[admin don insurance billing].freeze

  def show
    ActsAsTenant.with_tenant(current_user.agency) do
      @results = @review.criterion_results.includes(:policy_criterion).order("policy_criteria.position").to_a
      # Preload the documents the evidence cites, for deep-linking to the source.
      doc_ids = @results.filter_map { |r| r.evidence&.dig("doc_id") }.uniq
      @documents = @review.patient.patient_documents.with_attached_file.where(id: doc_ids).index_by(&:id)
    end
  end

  def sign_off
    ActsAsTenant.with_tenant(current_user.agency) do
      rec = params[:recommendation].to_s
      @review.recommendation = rec if PriorAuthReview.recommendations.key?(rec)
      @review.reviewed_by = current_user
      @review.status = :signed
      @review.save!

      Signatures::Apply.call(
        signable: @review, user: current_user, request: request,
        method:   :prior_auth_signoff,
        intent:   "I have reviewed this prior-authorization determination and authorized my electronic signature."
      )
      AgentEvent.create!(
        agency: current_user.agency, agent_id: current_user.role_names.first.presence || "clinician",
        action: "prior_auth_signoff", subject: @review, happened_at: Time.current,
        change_set: { recommendation: @review.recommendation }
      )
    end
    redirect_to prior_auth_review_path(@review), status: :see_other, notice: "Review signed."
  end

  private

  def set_review
    ActsAsTenant.with_tenant(current_user.agency) do
      @review = PriorAuthReview.includes(:patient, :coverage_policy, :reviewed_by).find(params[:id])
    end
  rescue ActiveRecord::RecordNotFound
    redirect_to dashboard_path, status: :see_other, alert: "Prior-auth review not found."
  end

  def authorize_reviewer!
    return if !current_user.family_access? && (current_user.role_names & REVIEWER_ROLES).any?
    redirect_to dashboard_path, status: :see_other, alert: "You don't have access to prior-auth reviews."
  end
end
