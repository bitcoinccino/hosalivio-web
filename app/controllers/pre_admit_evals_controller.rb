class PreAdmitEvalsController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_clinician!
  before_action :set_eval

  def show
    # Read-only view for clinicians; routes to edit for drafts/final
  end

  def edit
    unless @eval.status_draft? || @eval.status_final?
      redirect_to pre_admit_eval_path(@eval),
                  alert: "Can't edit — this eval has been certified or NOE-filed."
    end
  end

  def update
    unless @eval.status_draft? || @eval.status_final?
      redirect_to pre_admit_eval_path(@eval),
                  alert: "Certified evals are frozen for HHS audit. Create a new eval if a correction is needed."
      return
    end

    raw = existing_raw_json.deep_dup
    raw["pre_admit_eval"] ||= {}
    %w[general informed_consent election_of_benefit financial_consent diagnosis billing final_review medicare_lcd_criteria].each do |section|
      next unless params.dig(:pre_admit_eval, section).is_a?(ActionController::Parameters) ||
                  params.dig(:pre_admit_eval, section).is_a?(Hash)
      raw["pre_admit_eval"][section] = (raw["pre_admit_eval"][section] || {}).merge(
        params[:pre_admit_eval][section].permit!.to_h
      )
    end

    status_change = params[:submit_action] == "finalize" ? :final : @eval.status.to_sym
    @eval.assign_attributes(
      raw_json: raw,
      status:   status_change,
      finalized_at: (status_change == :final ? Time.current : @eval.finalized_at)
    )

    validation = PreAdmitValidator.call(raw)

    if status_change == :final && !validation.ok?
      flash.now[:alert] = "Can't finalize yet: #{validation.errors.first}"
      @eval.status = :draft
      render :edit, status: :unprocessable_entity
      return
    end

    if @eval.save
      flash[:notice] = status_change == :final ? "Eval finalized. Routed to MD for certification." : "Draft saved."
      redirect_to pre_admit_eval_path(@eval)
    else
      flash.now[:alert] = @eval.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_eval
    ActsAsTenant.with_tenant(current_user.agency) do
      @eval = PreAdmitEval.includes(:patient, :evaluator).find(params[:id])
    end
  end

  def existing_raw_json
    @eval.raw_json.is_a?(Hash) ? @eval.raw_json : {}
  end

  def authorize_clinician!
    return if current_user && !current_user.family_access?
    redirect_to welcome_path, alert: "Clinicians only."
  end
end
