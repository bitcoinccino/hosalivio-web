module Api
  module V1
    class PharmacyDeliveriesController < BaseController
      def index
        scope = policy_scope(PharmacyDelivery)
        scope = scope.where(patient_id: params[:patient_id]) if params[:patient_id]
        render json: PharmacyDeliverySerializer.new(scope.order(created_at: :desc).limit(100)).serializable_hash
      end

      def show
        delivery = PharmacyDelivery.find(params[:id])
        authorize delivery
        render json: PharmacyDeliverySerializer.new(delivery).serializable_hash
      end

      def create
        authorize PharmacyDelivery
        delivery = PharmacyDelivery.new(delivery_params.merge(agency: Current.agency))
        delivery.patient_id = params[:patient_id] if params[:patient_id]
        delivery.save!
        render json: PharmacyDeliverySerializer.new(delivery).serializable_hash, status: :created
      end

      def update
        delivery = PharmacyDelivery.find(params[:id])
        authorize delivery
        delivery.update!(delivery_params)
        render json: PharmacyDeliverySerializer.new(delivery).serializable_hash
      end

      private

      def delivery_params
        params.require(:pharmacy_delivery).permit(
          :patient_id, :medication_order_id, :confirmed_by_id,
          :kind, :status, :delivered_at
        )
      end
    end
  end
end
