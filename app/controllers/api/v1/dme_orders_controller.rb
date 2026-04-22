module Api
  module V1
    class DmeOrdersController < BaseController
      def index
        scope = policy_scope(DmeOrder)
        scope = scope.where(patient_id: params[:patient_id]) if params[:patient_id]
        render json: DmeOrderSerializer.new(scope.order(created_at: :desc).limit(100)).serializable_hash
      end

      def show
        order = DmeOrder.find(params[:id])
        authorize order
        render json: DmeOrderSerializer.new(order).serializable_hash
      end

      def create
        authorize DmeOrder
        order = DmeOrder.new(order_params.merge(agency: Current.agency))
        order.patient_id = params[:patient_id] if params[:patient_id]
        order.requested_at ||= Time.current
        order.save!
        render json: DmeOrderSerializer.new(order).serializable_hash, status: :created
      end

      def update
        order = DmeOrder.find(params[:id])
        authorize order
        order.update!(order_params)
        render json: DmeOrderSerializer.new(order).serializable_hash
      end

      private

      def order_params
        params.require(:dme_order).permit(
          :patient_id, :equipment_type, :quantity, :vendor, :status,
          :requested_at, :delivered_at, :picked_up_at, :notes
        )
      end
    end
  end
end
