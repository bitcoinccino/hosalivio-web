module Api
  module V1
    class MedicationOrdersController < BaseController
      def index
        scope = policy_scope(MedicationOrder)
        scope = scope.where(patient_id: params[:patient_id]) if params[:patient_id]
        render json: MedicationOrderSerializer.new(scope.order(created_at: :desc).limit(100)).serializable_hash
      end

      def show
        order = MedicationOrder.find(params[:id])
        authorize order
        render json: MedicationOrderSerializer.new(order).serializable_hash
      end

      def create
        authorize MedicationOrder
        order = MedicationOrder.new(order_params.merge(patient_id: params[:patient_id], agency: Current.agency))
        order.save!
        render json: MedicationOrderSerializer.new(order).serializable_hash, status: :created
      end

      def update
        order = MedicationOrder.find(params[:id])
        authorize order
        order.update!(order_params)
        render json: MedicationOrderSerializer.new(order).serializable_hash
      end

      private

      def order_params
        params.require(:medication_order).permit(
          :prescribed_by_id, :drug_name, :dose, :route, :frequency,
          :prn, :prn_indication, :start_date, :end_date, :status
        )
      end
    end
  end
end
