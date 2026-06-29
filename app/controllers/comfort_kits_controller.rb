# Emergency comfort-kit order set, scoped to an admission (PreAdmitEval).
#
# Two-step, human-in-the-loop, mirroring the eval's own certify flow:
#   1. The intake nurse reviews the 7 suggested kit meds, unchecks any, and
#      saves the rest as :draft MedicationOrders (no prescribing authority yet).
#   2. The MD authorizes the kit — Signatures::Gate → Signatures::Apply on each
#      order — which flips them :active and records the MD as prescriber.
class ComfortKitsController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_clinician!
  before_action :set_eval

  # Roles allowed to assemble/save the kit (the admission side). MD is added so
  # an MD reviewing the admission can also stage it; authorization is MD-only.
  KIT_EDITOR_ROLES = %w[admin don admissions rn md].freeze

  def show
    with_tenant do
      @orders = @eval.comfort_kit_orders.order(:controlled, :drug_name).to_a
      # No kit saved yet → offer the suggestion checklist for review.
      @suggestions = service.suggestions if @orders.empty?
    end
  end

  # POST — persist the nurse's selection as draft orders. Drug data comes from
  # the trusted constant via the service, keyed by the submitted selection only.
  def create
    return deny("Only the admission team can stage the comfort kit.") unless editor?
    with_tenant do
      if @eval.comfort_kit_orders.exists?
        return redirect_to(pre_admit_eval_comfort_kit_path(@eval), notice: "A comfort kit is already on file for this admission.")
      end
      drafts = service.build_drafts(params[:items])
      if drafts.empty?
        return redirect_to(pre_admit_eval_comfort_kit_path(@eval), alert: "Select at least one item to save.")
      end
      MedicationOrder.transaction { drafts.each(&:save!) }
      redirect_to pre_admit_eval_comfort_kit_path(@eval), status: :see_other,
                  notice: "#{drafts.size} comfort-kit orders saved as drafts — awaiting MD authorization."
    end
  end

  # POST — MD signs and activates the draft kit orders.
  def authorize
    unless current_user.role_names.include?("md")
      return deny("Only the MD can authorize the comfort kit.")
    end
    ok, err = Signatures::Gate.call(user: current_user, params: params)
    return redirect_to(pre_admit_eval_comfort_kit_path(@eval), alert: err) unless ok

    with_tenant do
      drafts = @eval.comfort_kit_orders.order_draft.to_a
      if drafts.empty?
        return redirect_to(pre_admit_eval_comfort_kit_path(@eval), notice: "No draft kit orders to authorize.")
      end
      intent = params[:intent_text].to_s.presence ||
               "I, the attending physician, authorize these comfort-kit medication orders and apply my electronic signature."
      MedicationOrder.transaction do
        drafts.each do |order|
          Signatures::Apply.call(signable: order, user: current_user, request: request,
                                 method: "comfort_kit_authorize", intent: intent)
          order.update!(status: :active, prescribed_by: current_user,
                        start_date: order.start_date || Date.current)
        end
      end
      redirect_to pre_admit_eval_comfort_kit_path(@eval), status: :see_other,
                  notice: "Comfort kit authorized and signed — #{drafts.size} orders now active."
    end
  end

  private

  def with_tenant(&block) = ActsAsTenant.with_tenant(current_user.agency, &block)

  def set_eval
    with_tenant { @eval = PreAdmitEval.includes(:patient).find(params[:pre_admit_eval_id]) }
  end

  def service
    @service ||= Medications::InitializeComfortKitService.new(eval: @eval, user: current_user)
  end

  def editor? = (current_user.role_names & KIT_EDITOR_ROLES).any?

  def authorize_clinician!
    return if current_user && !current_user.family_access?
    redirect_to welcome_path, alert: "Clinicians only."
  end

  def deny(msg) = redirect_to(pre_admit_eval_comfort_kit_path(@eval), alert: msg)
end
