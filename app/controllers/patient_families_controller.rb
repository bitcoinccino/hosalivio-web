class PatientFamiliesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_patient
  before_action :authorize_inviter!

  RELATIONSHIPS = %w[son daughter spouse partner parent sibling grandchild niece nephew
                     guardian caregiver friend other].freeze
  PRIVILEGED_ROLES = %w[admin don admissions].freeze

  def new
    @family_user = User.new(
      family_access: true,
      patient:       @patient,
      agency:        @patient.agency,
      timezone:      current_user.timezone.presence || "America/New_York"
    )
  end

  def create
    temp_password = generate_temp_password
    relationship  = normalized_relationship

    ActsAsTenant.with_tenant(@patient.agency) do
      @family_user = User.new(
        agency:        @patient.agency,
        patient:       @patient,
        family_access: true,
        full_name:     params.dig(:user, :full_name),
        email:         params.dig(:user, :email).to_s.downcase.strip,
        relationship:  relationship,
        timezone:      params.dig(:user, :timezone).presence || "America/New_York",
        password:      temp_password,
        password_confirmation: temp_password
      )

      if @family_user.save
        stamp_audit_event(relationship)
        begin
          FamilyInviteMailer.with(user: @family_user, patient: @patient,
                                   temp_password: temp_password,
                                   invited_by: current_user).welcome.deliver_later
        rescue => e
          Rails.logger.warn("[PatientFamilies] mailer failed for #{@family_user.email}: #{e.class} #{e.message}")
        end
        flash[:notice] = "Invited #{@family_user.full_name} (#{relationship} of #{@patient.first_name}). Temporary password: #{temp_password}"
        redirect_to patient_path(@patient)
      else
        flash.now[:alert] = @family_user.errors.full_messages.to_sentence
        render :new, status: :unprocessable_entity
      end
    end
  end

  def destroy
    ActsAsTenant.with_tenant(@patient.agency) do
      user = User.where(patient_id: @patient.id, family_access: true).find(params[:id])
      user.update!(active: false)
      redirect_to patient_path(@patient), notice: "Revoked family access for #{user.full_name}."
    end
  end

  private

  def set_patient
    ActsAsTenant.with_tenant(current_user.agency) do
      @patient = Patient.find(params[:patient_id])
    end
  end

  # Only the patient's assigned RN/MD, an admin, DON, or admissions coordinator
  # can invite family. Prevents a random clinician from granting chart access
  # to a patient outside their case load.
  def authorize_inviter!
    return if (current_user.role_names & PRIVILEGED_ROLES).any?
    return if [@patient.assigned_rn_id, @patient.assigned_md_id].include?(current_user.id)
    redirect_to patient_path(@patient), alert: "Only the assigned clinician, admin, DON, or admissions can invite family."
  end

  def normalized_relationship
    selected = params.dig(:user, :relationship).to_s.strip.downcase
    other    = params.dig(:user, :relationship_other).to_s.strip
    return other if selected == "other" && other.present?
    RELATIONSHIPS.include?(selected) ? selected : "family"
  end

  def generate_temp_password
    "hos-#{SecureRandom.alphanumeric(8).downcase}"
  end

  def stamp_audit_event(relationship)
    original_agency = Current.agency
    original_agent  = Current.agent_id
    original_sess   = Current.agent_session_id

    Current.agency           = @patient.agency
    Current.agent_id         = "system"
    Current.agent_session_id = "family-invite-#{SecureRandom.hex(3)}"

    AgentEvent.create!(
      agency:           @patient.agency,
      agent_id:         "system",
      agent_session_id: Current.agent_session_id,
      action:           "family_user_invited",
      subject:          @family_user,
      change_set: {
        patient_id:       @patient.id,
        patient_name:     @patient.full_name,
        relationship:     relationship,
        family_full_name: @family_user.full_name,
        family_email:     @family_user.email,
        invited_by_id:    current_user.id,
        invited_by_name:  current_user.full_name
      },
      happened_at: Time.current
    )
  ensure
    Current.agency           = original_agency
    Current.agent_id         = original_agent
    Current.agent_session_id = original_sess
  end
end
