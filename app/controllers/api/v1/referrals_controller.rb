require "fhir_models"

module Api
  module V1
    # Inbound FHIR R4 referral intake. A partner EMR authenticates as its agency
    # (Bearer AgentToken, handled by BaseController) and POSTs a referral Bundle.
    #
    # Pipeline: parse JSON → structural FHIR schema validation (reject invalid
    # instantly) → map to an Inquiry (which fans out to the on-call coordinator).
    # Every rejection is a FHIR OperationOutcome whose issues carry a FHIRPath
    # expression pointing at the offending element.
    class ReferralsController < BaseController
      def create
        raw = request.body.read

        begin
          parsed = JSON.parse(raw)
        rescue JSON::ParserError
          return render_outcome([ outcome_issue("Bundle", "Request body is not valid JSON.", code: "structure") ],
                                status: :bad_request)
        end

        model = FHIR.from_contents(raw)
        if model.nil?
          return render_outcome([ outcome_issue("Bundle", "Payload is not a recognized FHIR resource.", code: "structure") ],
                                status: :unprocessable_entity)
        end
        unless model.valid?
          return render_outcome(schema_issues(model), status: :unprocessable_entity)
        end

        result = Fhir::ReferralIngest.new(parsed, agency: Current.agency).call

        if result.ok?
          render json: info_outcome(
            result.duplicate? ? "Referral already received as inquiry #{result.inquiry.id}." \
                              : "Referral accepted as inquiry #{result.inquiry.id}."
          ).merge(inquiry_id: result.inquiry.id, duplicate: result.duplicate?),
                 status: result.duplicate? ? :ok : :created
        else
          render_outcome(result.issues.map { |i| outcome_issue(i[:expression], i[:message], code: i[:code]) },
                         status: :unprocessable_entity)
        end
      rescue Fhir::ReferralIngest::InvalidBundle => e
        render_outcome([ outcome_issue("Bundle", e.message, code: "invalid") ], status: :unprocessable_entity)
      rescue ActiveRecord::RecordInvalid => e
        issues = e.record.errors.full_messages.map { |m| outcome_issue("Inquiry", m, code: "required") }
        render_outcome(issues, status: :unprocessable_entity)
      end

      private

      # fhir_models nests errors ({ "entry" => [{ "resource" => [{ "status" => [msg] }]}]}).
      # Flatten to the leaf messages (which already carry "ResourceType.element: …")
      # and derive the FHIRPath expression from each message's prefix.
      def schema_issues(model)
        messages = collect_messages(model.validate)
        messages.map { |m| outcome_issue(expression_from(m), m, code: "structure") }.presence ||
          [ outcome_issue("Bundle", "Payload failed FHIR R4 schema validation.", code: "structure") ]
      end

      def collect_messages(node, acc = [])
        case node
        when Hash  then node.each_value { |v| collect_messages(v, acc) }
        when Array then node.each { |v| collect_messages(v, acc) }
        when String then acc << node
        end
        acc
      end

      def expression_from(message)
        prefix = message.to_s.split(":", 2).first.to_s.strip
        prefix.match?(/\A[A-Za-z]+(?:\.[A-Za-z\[\]0-9]+)*\z/) ? prefix : "Bundle"
      end

      def outcome_issue(expression, message, code:)
        { severity: "error", code: code, diagnostics: message, expression: [ expression ].compact }
      end

      def render_outcome(issues, status:)
        render json: { resourceType: "OperationOutcome", issue: issues }, status: status
      end

      def info_outcome(text)
        {
          resourceType: "OperationOutcome",
          issue: [ { severity: "information", code: "informational", details: { text: text } } ]
        }
      end
    end
  end
end
