module Api
  module V1
    # Inbound FHIR R4 referral intake. A partner EMR authenticates as its agency
    # (Bearer AgentToken, handled by BaseController) and POSTs a referral Bundle;
    # we turn it into an Inquiry in that agency, which fans out to the on-call
    # admissions coordinator like any other lead. Responds with a FHIR
    # OperationOutcome.
    class ReferralsController < BaseController
      def create
        bundle  = JSON.parse(request.body.read)
        inquiry = Fhir::ReferralIngest.new(bundle, agency: Current.agency).call

        render json: operation_outcome(
          severity: "information", code: "informational",
          text: "Referral accepted as inquiry #{inquiry.id}."
        ).merge(inquiry_id: inquiry.id), status: :created
      rescue JSON::ParserError
        render json: operation_outcome(severity: "error", code: "structure", text: "Request body is not valid JSON."),
               status: :bad_request
      rescue Fhir::ReferralIngest::InvalidBundle => e
        render json: operation_outcome(severity: "error", code: "invalid", text: e.message),
               status: :unprocessable_entity
      end

      private

      def operation_outcome(severity:, code:, text:)
        {
          resourceType: "OperationOutcome",
          issue: [ { severity: severity, code: code, details: { text: text } } ]
        }
      end
    end
  end
end
