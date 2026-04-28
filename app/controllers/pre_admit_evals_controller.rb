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

    # New section-based shape. Each section accepts a permissive merge
    # of its sub-keys, with array-string + boolean coercion applied
    # below. Old sections (informed_consent / election_of_benefit /
    # financial_consent) still accepted for backward compat with rows
    # written before the schema change.
    %w[
      header general_comments diagnosis current_medications other_symptoms
      cognitive_decline nutritional_decline functional_decline general
      informed_consent election_of_benefit financial_consent billing
      final_review medicare_lcd_criteria
    ].each do |section|
      next unless params.dig(:pre_admit_eval, section).is_a?(ActionController::Parameters) ||
                  params.dig(:pre_admit_eval, section).is_a?(Hash)
      raw["pre_admit_eval"][section] = (raw["pre_admit_eval"][section] || {}).deep_merge(
        params[:pre_admit_eval][section].permit!.to_h
      )
    end

    coerce_raw_json_types!(raw)

    status_change = params[:submit_action] == "finalize" ? :final : @eval.status.to_sym
    @eval.assign_attributes(
      raw_json: raw,
      status:   status_change,
      finalized_at: (status_change == :final ? Time.current : @eval.finalized_at)
    )

    # Cert-gate uses the model's certification_blockers, which already
    # reads the new section-based schema. Required at finalize so the
    # RN can't push an incomplete eval to the MD's review queue.
    if status_change == :final
      blockers = blockers_for(raw)
      if blockers.any?
        flash.now[:alert] = "Can't finalize yet: #{blockers.first}"
        @eval.status = :draft
        render :edit, status: :unprocessable_entity
        return
      end
    end

    if @eval.save
      flash[:notice] = status_change == :final ? "Eval finalized. Routed to MD for certification." : "Draft saved."
      redirect_to pre_admit_eval_path(@eval)
    else
      flash.now[:alert] = @eval.errors.full_messages.to_sentence
      render :edit, status: :unprocessable_entity
    end
  end

  # Flips PPS source from 'calculated' to 'clinician' so the AI's
  # suggestion becomes a confirmed clinical attestation. Score and
  # original justification stay for audit; we just change ownership
  # plus stamp who confirmed and when.
  def confirm_pps
    raw = existing_raw_json.deep_dup
    pps = raw.dig("pre_admit_eval", "functional_decline", "pps")
    if pps.is_a?(Hash) && pps["score"].to_i.between?(10, 100)
      raw["pre_admit_eval"]["functional_decline"]["pps"] = pps.merge(
        "source"          => "clinician",
        "confirmed_by_id" => current_user.id,
        "confirmed_at"    => Time.current.iso8601
      )
      @eval.update!(raw_json: raw)
      flash[:notice] = "PPS #{pps['score']}% confirmed."
    else
      flash[:alert] = "No calculated PPS to confirm."
    end
    redirect_to pre_admit_eval_path(@eval)
  end

  # One-tap blocker resolution from the show page. Whitelisted to the
  # two boolean attestations on `general` so the RN can mark
  # consent / patient-rights review without opening the full edit form.
  # Stamps who acknowledged + when into the same `general` block for audit.
  QUICK_SET_KEYS = %w[election_of_benefits_signed patient_rights_reviewed].freeze

  def quick_set
    key = params[:key].to_s
    unless QUICK_SET_KEYS.include?(key)
      redirect_to(pre_admit_eval_path(@eval), alert: "Unknown attestation.") and return
    end
    unless @eval.status_draft? || @eval.status_final?
      redirect_to(pre_admit_eval_path(@eval), alert: "This eval is locked.") and return
    end

    raw = existing_raw_json.deep_dup
    raw["pre_admit_eval"] ||= {}
    raw["pre_admit_eval"]["general"] ||= {}
    raw["pre_admit_eval"]["general"][key]                     = true
    raw["pre_admit_eval"]["general"]["#{key}_attested_by_id"] = current_user.id
    raw["pre_admit_eval"]["general"]["#{key}_attested_at"]    = Time.current.iso8601

    @eval.update!(raw_json: raw)
    flash[:notice] = "#{key.humanize} marked complete."
    redirect_to pre_admit_eval_path(@eval)
  end

  # Finalize action. Flips a draft eval to :final (which routes it to
  # the MD's certification queue) when the RN has cleared all blockers.
  # Triggered from the "Mark Complete & Route to MD" button on the show
  # page so the RN doesn't need to open the edit form just to submit.
  def finalize
    unless @eval.status_draft?
      redirect_to(pre_admit_eval_path(@eval), alert: "Eval is not in draft state.") and return
    end
    if @eval.certification_blockers.any?
      redirect_to(pre_admit_eval_path(@eval),
                  alert: "Resolve blockers first: #{@eval.certification_blockers.to_sentence}.") and return
    end
    @eval.update!(status: :final, finalized_at: Time.current)
    flash[:notice] = "Eval finalized. Routed to MD for certification."
    redirect_to pre_admit_eval_path(@eval)
  end

  # MD certification. Delegates the transition + downstream NOE
  # handoff to AgentTriager#certify_pre_admit_eval, which enforces
  # can_certify? and emits the Insurance handoff event.
  def certify
    unless current_user.role_names.include?("md")
      redirect_to(pre_admit_eval_path(@eval), alert: "Only the MD can sign certification.") and return
    end
    unless @eval.status_final?
      redirect_to(pre_admit_eval_path(@eval), alert: "Eval must be finalized by RN before MD certification.") and return
    end
    unless @eval.can_certify?
      redirect_to(pre_admit_eval_path(@eval), alert: "Resolve blockers first: #{@eval.certification_blockers.to_sentence}.") and return
    end

    AgentTriager.new(role: "md", agency: current_user.agency).apply({
      action:    "certify_pre_admit_eval",
      params:    { eval_id: @eval.id },
      reasoning: "MD certification by #{current_user.full_name}",
      source:    "ui:md_certify"
    })
    flash[:notice] = "Certification signed. Routed to Insurance for NOE filing."
    redirect_to pre_admit_eval_path(@eval.reload)
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

  # Mirror of PreAdmitEval#certification_blockers, but reads from the
  # in-memory `raw` hash before save instead of the persisted record.
  # Used by the finalize gate so the RN gets immediate feedback if the
  # form is missing something.
  def blockers_for(raw)
    pae = raw["pre_admit_eval"] || {}
    gen = pae["general"] || {}
    dx  = pae["diagnosis"] || {}
    pdx = dx["primary_terminal_diagnosis"].is_a?(Hash) ? dx["primary_terminal_diagnosis"] : {}
    lcd = Array(dx["lcd_criteria_met"])

    blockers = []
    blockers << "Election of benefits not signed"   unless gen["election_of_benefits_signed"] == true
    blockers << "Patient rights not reviewed"       unless gen["patient_rights_reviewed"] == true
    blockers << "Primary diagnosis ICD-10 missing"  if pdx["icd10"].to_s.strip.empty?
    blockers << "LCD criteria not supported"        if lcd.empty?
    blockers
  end

  # Form fields are all strings; some target array / boolean / integer
  # destinations. Coerce them to the right Ruby types so the JSON
  # round-trip stays clean and the cert-gate booleans actually flip.
  def coerce_raw_json_types!(raw)
    pae = raw["pre_admit_eval"] || {}

    # immediate_safety_risks and dme_needs come in as comma-strings
    %w[general_comments general].each do |sec|
      next unless pae[sec].is_a?(Hash)
      %w[immediate_safety_risks dme_needs].each do |k|
        v = pae[sec][k]
        if v.is_a?(String)
          pae[sec][k] = v.split(/[,\n]/).map(&:strip).reject(&:empty?)
        end
      end
    end

    # Cert-gate booleans
    if pae["general"].is_a?(Hash)
      %w[election_of_benefits_signed patient_rights_reviewed].each do |k|
        if pae["general"].key?(k)
          pae["general"][k] = ActiveModel::Type::Boolean.new.cast(pae["general"][k]) || false
        end
      end
    end

    # PPS score + KPS as integers, score is the structured object key
    fd = pae["functional_decline"]
    if fd.is_a?(Hash)
      if fd["pps"].is_a?(Hash) && fd["pps"]["score"].is_a?(String)
        fd["pps"]["score"] = fd["pps"]["score"].to_i
      end
      fd["kps"] = fd["kps"].to_i if fd["kps"].is_a?(String) && fd["kps"].present?
    end
  end

  def authorize_clinician!
    return if current_user && !current_user.family_access?
    redirect_to welcome_path, alert: "Clinicians only."
  end
end
