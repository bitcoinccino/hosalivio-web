# Patient-side consent capture. Two signing paths:
#   1. Clinician-witnessed at the admission visit — the Admission RN (or any
#      assigned clinician / admin) opens /patients/:id/consents/new, the
#      patient/representative signs on the RN's device, witnessed_by = the RN.
#   2. Patient/family self-serve — when they weren't ready at the visit and
#      want time, they sign the required forms themselves in their portal;
#      witnessed_by = the patient's clinician of record (assigned RN → MD).
# DNR is clinician-only (it flips code_status); families can't self-sign it.
class ConsentFormsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_patient
  before_action :authorize_patient_access!
  before_action :authorize_signing!, only: [ :new, :create ]

  def index
    @consents             = @patient.consent_forms.recent_first
    @outstanding_required = ConsentForm.outstanding_required_for(@patient)
  end

  def show
    # @consent + @patient set in set_patient
  end

  def new
    kind = requested_kind.presence || (family_signer? ? ConsentForm::REQUIRED_KINDS.first : "hospice_election")
    @consent = ConsentForm.new(patient: @patient, kind: kind, signer_role: "patient")
    @witness = witness_for
    @guided  = params[:flow] == "required"
  end

  def create
    permitted = consent_params
    data_url  = permitted.delete(:signature_data_url).to_s
    @witness  = witness_for
    @guided   = params[:flow] == "required"

    @consent = ConsentForm.new(permitted.merge(
      patient:      @patient,
      witnessed_by: @witness,
      signed_at:    Time.current,
      form_content: ConsentForm.attestation_for(permitted[:kind], agency: @patient.agency)
    ))

    if data_url.blank? || !data_url.start_with?("data:image/")
      @consent.errors.add(:base, "Signature is required — draw on the pad before submitting.")
      return render(:new, status: :unprocessable_entity)
    end

    if @consent.save
      bytes = Base64.decode64(data_url.split(",", 2).last.to_s)
      @consent.signature_image.attach(
        io:           StringIO.new(bytes),
        filename:     "consent-#{@consent.id}.png",
        content_type: "image/png"
      )
      Signatures::Apply.call(
        signable: @consent,
        user:     current_user,
        request:  request,
        method:   @consent.signed_by_patient? ? "drawn_inline_by_patient" : "drawn_inline_by_representative",
        intent:   "Signature for #{@consent.kind_label}. Signer: #{@consent.signer_label}. Witness of record: #{@witness&.full_name}."
      )

      # A signed DNR mirrors the patient's code_status so downstream clinical
      # views update without manual sync. (Clinician-only path.)
      if @consent.kind == "dnr"
        @patient.update(code_status: :dnr) if @patient.code_status != "dnr"
      end

      after_sign_redirect
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def family_signer? = current_user.family_access?

  # Clinician signs in front of the patient → the clinician witnesses.
  # Patient/family self-signs → the patient's clinician of record.
  def witness_for
    family_signer? ? @patient.consent_witness_of_record : current_user
  end

  def set_patient
    ActsAsTenant.with_tenant(current_user.agency) do
      if params[:patient_id].present?
        @patient = Patient.find(params[:patient_id])
      else
        @consent = ConsentForm.find(params[:id])
        @patient = @consent.patient
      end
    end
  end

  # Family may only touch their own patient; clinicians are already scoped to
  # their agency by the tenant block.
  def authorize_patient_access!
    return unless family_signer?
    return if current_user.patient_id == @patient.id
    redirect_to root_path, status: :see_other, alert: "You can only view your own consents."
  end

  # new/create gate. Family: required kinds only, and only once a clinician of
  # record exists to witness. Clinicians: the existing assigned/visit/admin gate.
  def authorize_signing!
    if family_signer?
      unless ConsentForm::REQUIRED_KINDS.include?(requested_kind)
        return redirect_to(patient_consents_path(@patient), status: :see_other,
          alert: "That form is completed with your care team.")
      end
      unless @patient.consent_witness_of_record
        redirect_to patient_consents_path(@patient), status: :see_other,
          alert: "Your care team will set this up — no admission nurse is assigned yet."
      end
    else
      authorize_consent_witness!
    end
  end

  def requested_kind
    (params.dig(:consent_form, :kind) || params[:kind]).to_s
  end

  # In the guided "sign each form" flow, advance to the next outstanding
  # required form after each signature; when none remain, land on the index.
  def after_sign_redirect
    if @guided
      nxt = ConsentForm.outstanding_required_for(@patient).first
      return redirect_to(new_patient_consent_path(@patient, kind: nxt, flow: "required"),
        notice: "#{@consent.kind_label} signed. Next form is ready.") if nxt
      return redirect_to(patient_consents_path(@patient),
        notice: "All required consents are signed. Thank you.")
    end
    redirect_to patient_consent_path(@patient, @consent), notice: "Consent recorded."
  end

  # Witnessing a consent (and the DNR -> code_status flip) is a clinical act for
  # THIS patient: only the patient's assigned clinicians, a clinician who has a
  # visit with them (the admitting RN), or an agency manager may do it.
  CONSENT_MANAGER_ROLES = %w[admin admissions].freeze
  def authorize_consent_witness!
    return if (current_user.role_names & CONSENT_MANAGER_ROLES).any?
    assigned_ids = [ @patient.assigned_rn_id, @patient.assigned_md_id,
                    @patient.assigned_sw_id, @patient.assigned_chaplain_id ].compact
    return if assigned_ids.include?(current_user.id)
    return if @patient.visits.where(user_id: current_user.id).exists?
    redirect_to dashboard_path, status: :see_other,
                alert: "Only the patient's assigned clinician or an admin can witness consents."
  end

  def consent_params
    params.require(:consent_form).permit(
      :kind, :signer_role, :signer_name, :signer_relationship,
      :signer_authority, :signature_data_url
    )
  end
end
