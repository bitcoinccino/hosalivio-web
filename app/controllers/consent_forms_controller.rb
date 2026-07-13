# Patient-side consent capture. The witnessing clinician (any role
# — admissions RN, MD, SW) opens /patients/:id/consents/new on
# their tablet, the patient or family member fills the signer block
# + draws their signature on the canvas, and submitting persists
# both the consent_forms row and a polymorphic Signature audit row.
# No registered-signature reuse here — patient/family always sign
# fresh, every time, in front of the witnessing clinician.
class ConsentFormsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_patient, only: [ :index, :new, :create ]
  before_action :authorize_consent_witness!, only: [ :new, :create ]

  def index
    ActsAsTenant.with_tenant(current_user.agency) do
      @patient  = Patient.find(params[:patient_id])
      @consents = @patient.consent_forms.recent_first
    end
  end

  def show
    ActsAsTenant.with_tenant(current_user.agency) do
      @consent = ConsentForm.find(params[:id])
      @patient = @consent.patient
    end
  end

  def new
    @consent = ConsentForm.new(
      patient:  @patient,
      kind:     params[:kind].to_s.presence || "hospice_election",
      signer_role: "patient"
    )
  end

  def create
    permitted = consent_params
    data_url  = permitted.delete(:signature_data_url).to_s

    @consent = ConsentForm.new(permitted.merge(
      patient:      @patient,
      witnessed_by: current_user,
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
        intent:   "Witnessed signature for #{@consent.kind_label}. Signer: #{@consent.signer_label}."
      )

      # If the consent is a DNR, mirror the patient's code_status so
      # downstream views (clinical flags chip on visit edit) update
      # without manual sync.
      if @consent.kind == "dnr"
        @patient.update(code_status: :dnr) if @patient.code_status != "dnr"
      end

      redirect_to patient_consent_path(@patient, @consent), notice: "Consent recorded."
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  # Witnessing a consent (and the DNR -> code_status flip) is a clinical act
  # for THIS patient: only the patient's assigned clinicians, a clinician who
  # has a visit with them (the admitting RN witnessing during the visit), or an
  # agency manager may do it. Blocks unassigned clinicians and family users.
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

  def set_patient
    ActsAsTenant.with_tenant(current_user.agency) do
      @patient = Patient.find(params[:patient_id])
    end
  end

  def consent_params
    params.require(:consent_form).permit(
      :kind, :signer_role, :signer_name, :signer_relationship,
      :signer_authority, :signature_data_url
    )
  end
end
