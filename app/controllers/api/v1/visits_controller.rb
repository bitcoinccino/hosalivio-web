module Api
  module V1
    class VisitsController < BaseController
      def index
        visits = policy_scope(Visit).where(patient_id: params[:patient_id]).order(started_at: :desc).limit(100)
        render json: VisitSerializer.new(visits).serializable_hash
      end

      def create
        authorize Visit
        visit = Visit.new(visit_params.merge(patient_id: params[:patient_id], agency: Current.agency))
        visit.save!
        render json: VisitSerializer.new(visit).serializable_hash, status: :created
      end

      private

      def visit_params
        params.require(:visit).permit(
          :user_id, :discipline, :visit_type,
          :scheduled_at, :started_at, :ended_at,
          :narrative, :pain_score, :billable, :visit_code,
          vitals: {}
        )
      end
    end
  end
end
