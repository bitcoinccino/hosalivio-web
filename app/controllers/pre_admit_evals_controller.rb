class PreAdmitEvalsController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_clinician!
  before_action :set_patient, only: :index
  before_action :set_eval,    except: [ :index, :queue ]

  # A patient's admission-eval history, newest first.
  def index
    @evals = ActsAsTenant.with_tenant(current_user.agency) do
      @patient.pre_admit_evals.order(created_at: :desc).to_a
    end
  end

  # Cross-patient admissions worklist: in-flight evals grouped by stage,
  # NOE-critical ones ordered by their deadline.
  def queue
    ActsAsTenant.with_tenant(current_user.agency) do
      base          = PreAdmitEval.where(agency: current_user.agency).includes(:patient)
      @drafts       = base.where(status: :draft).order(created_at: :desc).to_a
      @awaiting_md  = base.where(status: :final).order(created_at: :desc).to_a
      @awaiting_noe = base.where(status: :certified).order(:noe_deadline_at).to_a
      @completed    = base.where(status: [ :noe_filed, :revoked ]).order(updated_at: :desc).limit(15).to_a
    end
  end

  def show
    # Read-only view for clinicians; routes to edit for drafts/final
  end

  # Retired: editing now happens via per-card modals on the show page.
  # Kept as a redirect so any lingering /edit links land somewhere sane.
  def edit
    redirect_to pre_admit_eval_path(@eval)
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
      final_review medicare_lcd_criteria referral_context
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
        redirect_to pre_admit_eval_path(@eval), alert: "Can't finalize yet: #{blockers.first}"
        return
      end
    end

    if @eval.save
      flash[:notice] = status_change == :final ? "Eval finalized. Routed to MD for certification." : "Saved."
      redirect_to pre_admit_eval_path(@eval)
    else
      redirect_to pre_admit_eval_path(@eval), alert: @eval.errors.full_messages.to_sentence
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
    redirect_to quick_set_return_path
  end

  # The attestation buttons live in two places: the eval show page and the
  # RN's certification checklist on the visit edit page. `return_to=visit`
  # keeps the RN on the visit page (where they're reviewing + routing)
  # instead of bouncing them to the standalone eval.
  def quick_set_return_path
    if params[:return_to].to_s == "visit" && @eval.visit
      edit_visit_path(@eval.visit)
    else
      pre_admit_eval_path(@eval)
    end
  end
  private :quick_set_return_path

  # Saves the RN's accepted DME / equipment selections (AI-suggested or
  # manual) plus free-text notes into the `general` block. Posted from the
  # actionable DME section on the show page so the RN can confirm equipment
  # without opening the full edit form.
  def save_dme
    unless @eval.status_draft? || @eval.status_final?
      redirect_to(pre_admit_eval_path(@eval), alert: "This eval is locked.") and return
    end

    raw = existing_raw_json.deep_dup
    raw["pre_admit_eval"] ||= {}
    raw["pre_admit_eval"]["general"] ||= {}
    raw["pre_admit_eval"]["general"]["dme_needs"] =
      Array(params[:dme_needs]).map { |s| s.to_s.strip }.reject(&:blank?).uniq
    raw["pre_admit_eval"]["general"]["dme_notes"] = params[:dme_notes].to_s.strip.presence

    @eval.update!(raw_json: raw)
    flash[:notice] = "Equipment needs saved."
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
  # POST /pre_admit_evals/:id/retry_sync — manually (re)queue the outbound
  # VITAS transmission. Used when a sync failed, or when gateway credentials
  # land after an eval was already certified (the auto-fire on certification
  # no-opped because the gateway was dormant).
  def retry_sync
    unless (current_user.role_names & %w[admin don md]).any?
      redirect_to(pre_admit_eval_path(@eval), alert: "Only admin / DON / MD can trigger an EMR sync.") and return
    end

    if @eval.enqueue_emr_sync
      @eval.update!(sync_status: :processing)
      redirect_to pre_admit_eval_path(@eval), notice: "VITAS sync queued — the chip will update when the gateway responds."
    else
      redirect_to pre_admit_eval_path(@eval),
                  alert: "VITAS gateway isn't configured yet (set VITAS_GATEWAY_URL and VITAS_API_BEARER_TOKEN). Nothing was sent."
    end
  end

  # GET — download the eval as a schema-valid FHIR R4 document bundle. Any
  # clinician can export once the eval is out of draft ("after the note"). Needs
  # no external credentials, so it works today; complements the gateway-gated
  # auto-sync (the nurse hands the bundle to / uploads it into their EMR).
  def export_fhir
    if @eval.status_draft?
      redirect_to(pre_admit_eval_path(@eval), alert: "Finalize the eval before exporting to the EMR.") and return
    end

    bundle = ActsAsTenant.with_tenant(@eval.agency) do
      b = @eval.compile_fhir_bundle
      # Audit the PHI export in the same trail as convert/certify.
      AgentEvent.create!(
        agency:           @eval.agency,
        agent_id:         current_user.role_names.first.presence || "clinician",
        agent_session_id: "export-#{current_user.id.to_s[0, 8]}",
        action:           "eval_fhir_exported",
        subject:          @eval,
        change_set: {
          exported_by:      current_user.full_name,
          exported_by_role: current_user.role_names.join("/"),
          format:           "application/fhir+json",
          eval_status:      @eval.status,
          patient_id:       @eval.patient_id,
          resource_count:   Array(b[:entry]).size
        },
        happened_at: Time.current
      )
      b
    end
    Rails.logger.info("[pre_admit_evals#export_fhir] eval=#{@eval.id} by=#{current_user.id} roles=#{current_user.role_names.join('/')}")

    send_data JSON.pretty_generate(bundle),
              filename:    "pre-admit-eval-#{@eval.id}.fhir.json",
              type:        "application/fhir+json",
              disposition: "attachment"
  end

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

    ok, err = Signatures::Gate.call(user: current_user, params: params)
    unless ok
      redirect_to(pre_admit_eval_path(@eval), alert: err) and return
    end

    Signatures::Apply.call(
      signable: @eval,
      user:     current_user,
      request:  request,
      method:   "md_certify",
      intent:   params[:intent_text].to_s.presence ||
                "I, the on-call physician, certify this pre-admit evaluation as supporting hospice eligibility and authorize the application of my electronic signature."
    )

    AgentTriager.new(role: "md", agency: current_user.agency).apply({
      action:    "certify_pre_admit_eval",
      params:    { eval_id: @eval.id },
      reasoning: "MD certification by #{current_user.full_name}",
      source:    "ui:md_certify"
    })

    # Notify the assigned RN (the one who did the admission visit)
    # that their eval was certified. Goes through the same Notification
    # → OutboundPing pipeline as everything else, so Pascal gets a
    # Telegram / SMS / email ping if those channels are enabled.
    notify_admission_rn_of_certification(@eval.reload)

    # Push the now-certified eval to the external EMR (VITAS portal).
    # Dormant until the gateway is configured; safe no-op otherwise.
    @eval.enqueue_emr_sync

    flash[:notice] = "Certification signed. Routed to Insurance for NOE filing."
    redirect_to pre_admit_eval_path(@eval)
  end

  # POST /pre_admit_evals/:id/request_changes — MD has reviewed the
  # finalized eval and wants the RN to revise something before they
  # certify. Bounces the eval back to :draft, captures the MD's
  # comment + a snapshot hash for audit, and pings the RN through
  # the same Notification → OutboundPing pipeline. The next time
  # the RN re-routes via the visit edit page, route_to_md resolves
  # any open requests.
  def request_changes
    unless current_user.role_names.include?("md")
      redirect_to(pre_admit_eval_path(@eval), alert: "Only the MD can request changes.") and return
    end
    unless @eval.status_final?
      redirect_to(pre_admit_eval_path(@eval), alert: "Eval isn't awaiting your review.") and return
    end

    comment = params[:comment].to_s.strip
    if comment.length < 5
      redirect_to(pre_admit_eval_path(@eval), alert: "Add a brief explanation of what needs to change.") and return
    end

    EvalRevisionRequest.create!(
      pre_admit_eval: @eval,
      requester:      current_user,
      comment:        comment,
      document_hash:  Digest::SHA256.hexdigest(@eval.attributes.except("updated_at").sort.to_h.to_json)
    )
    @eval.update!(status: :draft)

    notify_rn_of_revision_request(@eval, comment)

    flash[:notice] = "Sent back to the RN with your comment."
    redirect_to pre_admit_eval_path(@eval)
  end

  private

  # Notify the eval's evaluator (admission RN) that the MD wants
  # changes. Same pipeline as every other Notification — the RN
  # gets an OutboundPing for their preferred channel(s).
  def notify_rn_of_revision_request(eval_rec, comment)
    target = eval_rec.evaluator || eval_rec.patient&.assigned_rn
    return unless target
    Notification.create!(
      agency: eval_rec.agency,
      user:   target,
      kind:   "eval_revision_requested",
      title:  "MD requested changes to the pre-admit eval for #{eval_rec.patient.full_name}",
      body:   comment.truncate(280),
      linked: eval_rec
    )
  rescue => e
    Rails.logger.warn("[pre_admit_evals#request_changes] notify failed: #{e.message}")
  end

  # Sends one Notification to the eval's evaluator (typically the
  # admission RN) and another to the patient's assigned_rn if that's
  # a different person. The Notification's after_create_commit hook
  # auto-enqueues an OutboundPing for the user's preferred channels.
  # Idempotent — Notification is keyed on (user, kind, linked_id).
  def notify_admission_rn_of_certification(eval_rec)
    targets = [ eval_rec.evaluator, eval_rec.patient&.assigned_rn ].compact.uniq
    targets.each do |target|
      next if Notification.exists?(user: target, kind: "pre_admit_certified", linked: eval_rec)
      Notification.create!(
        agency: eval_rec.agency,
        user:   target,
        kind:   "pre_admit_certified",
        title:  "Pre-admit eval certified for #{eval_rec.patient&.full_name}",
        linked: eval_rec
      )
    end
  rescue => e
    Rails.logger.warn("[pre_admit_evals#certify] notify failed: #{e.message}")
  end

  def set_eval
    ActsAsTenant.with_tenant(current_user.agency) do
      @eval = PreAdmitEval.includes(:patient, :evaluator).find(params[:id])
    end
  end

  def set_patient
    ActsAsTenant.with_tenant(current_user.agency) do
      @patient = Patient.find(params[:patient_id])
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
        elsif v.is_a?(Array)
          pae[sec][k] = v.flat_map { |item| item.to_s.split(/[,\n]/) }.map(&:strip).reject(&:empty?)
        end
      end
    end

    if pae["diagnosis"].is_a?(Hash) && pae["diagnosis"]["lcd_criteria_met"].is_a?(String)
      pae["diagnosis"]["lcd_criteria_met"] =
        pae["diagnosis"]["lcd_criteria_met"].split(/[,\n]/).map(&:strip).reject(&:empty?)
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
