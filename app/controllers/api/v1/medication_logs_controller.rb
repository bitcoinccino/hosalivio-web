module Api
  module V1
    class MedicationLogsController < BaseController
      def index
        logs = policy_scope(MedicationLog)
                 .where(medication_order_id: params[:medication_order_id])
                 .order(administered_at: :desc).limit(100)
        render json: MedicationLogSerializer.new(logs).serializable_hash
      end

      def create
        authorize MedicationLog
        log = MedicationLog.new(
          log_params.merge(
            medication_order_id: params[:medication_order_id],
            agency: Current.agency
          )
        )
        log.save!
        render json: MedicationLogSerializer.new(log).serializable_hash, status: :created
      end

      private

      def log_params
        params.require(:medication_log).permit(
          :administered_by_id, :administered_at, :dose_given,
          :effective, :side_effects, :source
        )
      end
    end
  end
end
