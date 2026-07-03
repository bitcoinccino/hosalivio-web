# The coordination queue — the operations room where the two isolated
# top-of-funnel streams meet for human triage:
#   • unconverted Inquiry leads (from the FHIR ingest + landing form), waiting
#     for a coordinator to convert_to_patient, and
#   • newly-registered Patients (status: referred) that still need a visit
#     scheduled and their insurance verified.
#
# Both streams stay in their own tables (the lead/patient privacy wall); this
# view only reads them side by side.
class CoordinationController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_coordinator!

  COORDINATOR_ROLES = %w[admin don admissions].freeze

  def index
    ActsAsTenant.with_tenant(current_user.agency) do
      @leads = Inquiry.where(status: [ :new_lead, :claimed, :contacted ])
                      .includes(:claimed_by)
                      .order(created_at: :desc).limit(100).to_a

      @new_patients = Patient.where(status: :referred)
                             .includes(:assigned_rn)
                             .order(created_at: :desc).limit(100).to_a

      # Compact NOE signal; the full worklist lives in the admissions queue.
      @noe_overdue = PreAdmitEval.where(status: :certified).select(&:noe_overdue?).size
    end
  end

  private

  def authorize_coordinator!
    return if current_user && (current_user.role_names & COORDINATOR_ROLES).any?
    redirect_to dashboard_path, alert: "Only admin, DON, or admissions can view the coordination queue."
  end
end
