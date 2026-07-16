class InquiriesController < ApplicationController
  # Renders inside the Mission shell (nav rail + banner) rather than
  # standalone; @mission_nav drives the highlight and the banner title.
  layout "mission", only: [ :index ]
  before_action -> { @mission_nav = :referrals }, only: [ :index ]
  # Public `create` for the landing page. Auth-required for everything else.
  skip_before_action :verify_authenticity_token, only: :create    # JSON POST from public page
  before_action :authenticate_user!, except: :create
  # The inquiries inbox (view / claim / contact / dismiss / convert-to-patient)
  # is an admissions/admin intake task, not clinical work. Only the public
  # landing-page submission (:create) is open.
  before_action :authorize_inquiry_manager!, except: :create

  before_action :set_inquiry, only: [ :show, :claim, :mark_contacted, :defer, :dismiss, :convert, :convert_to_patient ]

  # ── Public submission from landing page ──────────────────────────────
  def create
    partner = target_agency(params[:agency_id])
    return render json: { error: "no_agencies_configured" }, status: :service_unavailable if partner.nil?

    caregiver_phone = params[:caregiver_phone].to_s.strip
    email           = params[:email].to_s.strip
    # `contact` stays the canonical "how to reach you" the alert/inbox already
    # use: prefer the caregiver phone, fall back to email (or a legacy single
    # `contact` field from older callers).
    contact         = params[:contact].to_s.strip.presence || caregiver_phone.presence || email

    ActsAsTenant.with_tenant(partner) do
      inquiry = Inquiry.create!(
        agency:          partner,
        is_general:      params[:agency_id].blank?,
        first_name:      (params[:first_name].presence || params[:name]).to_s.strip.presence,
        last_name:       params[:last_name].to_s.strip.presence,
        dob:             params[:dob].to_s.strip.presence,
        caregiver_phone: caregiver_phone.presence,
        email:           email.presence,
        diagnosis:       params[:diagnosis].to_s.strip.presence,
        payer:           params[:payer].to_s.strip.presence,
        requester_role:  params[:requester_role].to_s.strip.presence,
        contact:         contact,
        zip:             params[:zip].to_s.strip,
        question:        params[:question].to_s.strip,
        preferred_date:  params[:preferred_date].to_s.strip.presence,
        preferred_slot:  params[:preferred_slot].to_s.strip.presence,
        source_prompt:   params[:source_prompt].to_s.presence || "capture",
        routed_to_role:  params[:routed_to_role].to_s.presence || "admissions",
        status:          :new_lead
      )
      render json: { status: "ok", id: inquiry.id, agency: partner.name }, status: :created
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "invalid", details: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  # ── Staff inbox (one agency at a time) ──────────────────────────────
  def index
    redirect_to(root_path) and return if current_user.family_access?
    ActsAsTenant.with_tenant(current_user.agency) do
      @agency = current_user.agency
      # The inbox tracks open work: leads to claim, claimed leads to convert,
      # contacted-but-not-yet-converted leads, plus "considering" leads parked
      # for follow-up. Converted/dismissed drop off.
      open_scope     = Inquiry.where(status: [ :new_lead, :claimed, :contacted, :considering ])
      raw_counts     = open_scope.group(:status).count
      # group(:status).count can key by enum label or raw integer depending on
      # the adapter; normalize to label strings either way.
      @status_counts = raw_counts.transform_keys { |k| k.is_a?(Integer) ? Inquiry.statuses.key(k) : k.to_s }
      @open_total    = @status_counts.values.sum
      # Parked "still deciding" leads whose follow-up date has arrived.
      @followups_due = Inquiry.status_considering.where("follow_up_at <= ?", Time.current).count
      @status        = params[:status].presence_in(%w[new_lead claimed contacted considering])
      list           = @status ? open_scope.where(status: @status) : open_scope
      order          = @status == "considering" ? { follow_up_at: :asc } : { created_at: :desc }
      @inquiries     = list.order(order).limit(100)
    end
    respond_to do |f|
      f.html
      f.json { render json: @inquiries.map { |i| inquiry_json(i) } }
    end
  end

  # ── Inquiry detail — the decision hub (claim / contact / dismiss / convert) ──
  def show
    respond_to do |f|
      f.html
      f.json { render json: inquiry_json(@inquiry) }
    end
  end

  def claim
    @inquiry.update!(claimed_by: current_user, claimed_at: Time.current, status: :claimed)
    redirect_back fallback_location: inquiries_path, notice: "Claimed — call them within the hour."
  end

  def mark_contacted
    @inquiry.update!(contacted_at: Time.current, status: :contacted)
    redirect_back fallback_location: inquiries_path, notice: "Marked contacted."
  end

  # POST /inquiries/:id/defer — family is unsure and needs time to decide.
  # Parks the lead as "considering" with a follow-up date so it resurfaces
  # instead of going cold (or being wrongly dismissed as declined).
  def defer
    days = params[:follow_up_in_days].to_i
    at   = params[:follow_up_at].presence
    follow_up = at ? Time.zone.parse(at) : (days > 0 ? days.days.from_now : 1.week.from_now)
    @inquiry.update!(status: :considering, follow_up_at: follow_up)
    redirect_back fallback_location: inquiry_path(@inquiry),
                  notice: "Marked as still deciding — follow up #{follow_up.to_date.strftime('%b %-d')}."
  end

  def dismiss
    @inquiry.update!(status: :dismissed)
    redirect_back fallback_location: inquiries_path, notice: "Dismissed."
  end

  # GET /inquiries/:id/convert — quick-confirm form for the admissions coordinator
  def convert
    redirect_to(dashboard_path, alert: "Already converted.") and return if @inquiry.status_converted?
  end

  # POST /inquiries/:id/convert_to_patient — the atomic bridge
  def convert_to_patient
    if @inquiry.status_converted?
      redirect_to(dashboard_path, alert: "Already converted.") and return
    end

    patient = nil
    ActsAsTenant.with_tenant(current_user.agency) do
      Inquiry.transaction do
        phone, email = split_contact(@inquiry.contact)

        patient = Patient.create!(
          agency:            current_user.agency,
          first_name:        params[:first_name].presence || @inquiry.first_name.to_s.strip,
          last_name:         params[:last_name].presence || @inquiry.last_name.to_s.strip,
          dob:               params[:dob].presence || @inquiry.dob.presence,
          gender:            params[:gender].presence,
          primary_diagnosis: params[:primary_diagnosis].presence || @inquiry.diagnosis.to_s.strip,
          zip:               @inquiry.zip.to_s.strip,
          phone:             phone || @inquiry.caregiver_phone.presence,
          email:             email || @inquiry.email.presence,
          caregiver_name:    params[:caregiver_name].presence,
          caregiver_phone:   params[:caregiver_phone].presence || @inquiry.caregiver_phone.presence,
          status:            :referred,
          code_status:       params[:code_status].presence || :full_code
        )

        if @inquiry.question.to_s.strip.present?
          Note.create!(
            agency:      current_user.agency,
            patient:     patient,
            author_role: "admissions",
            author_user: current_user,
            body:        "Inquiry context (pre-admission, via #{@inquiry.source_prompt.to_s.tr('_', ' ')}):\n\n\"#{@inquiry.question.strip}\"",
            urgency:     :normal,
            source:      :system
          )
        end

        @inquiry.update!(
          status:            :converted,
          converted_at:      Time.current,
          converted_patient: patient
        )

        AgentEvent.create!(
          agency:           current_user.agency,
          agent_id:         "admissions",
          agent_session_id: "convert-#{current_user.id.to_s[0, 8]}",
          action:           "inquiry_converted",
          subject:          @inquiry,
          change_set: {
            first_name:   @inquiry.first_name,
            patient_id:   patient.id,
            patient_mrn:  patient.mrn,
            converted_by: current_user.full_name
          },
          happened_at: Time.current
        )
      end
    end

    redirect_to patient_path(patient),
                notice: "#{patient.full_name} is now in your active census as #{patient.mrn}. The inquiry question is the first chart note."
  rescue ActiveRecord::RecordInvalid => e
    flash.now[:alert] = "Couldn't convert: #{e.record.errors.full_messages.to_sentence}"
    render :convert, status: :unprocessable_entity
  end

  # ── helpers ─────────────────────────────────────────────────────────
  private

  INQUIRY_MANAGER_ROLES = %w[admin admissions].freeze
  def authorize_inquiry_manager!
    return if (current_user.role_names & INQUIRY_MANAGER_ROLES).any?
    redirect_to dashboard_path, status: :see_other,
                alert: "Only admin, DON, or admissions can manage inquiries."
  end

  def set_inquiry
    ActsAsTenant.with_tenant(current_user&.agency) do
      @inquiry = Inquiry.find(params[:id])
    end
  end

  # Resolve which agency to attach the inquiry to.
  # Targeted: the partner whose "Contact" card was clicked.
  # General: the HosAlivio flagship (slug HOS), or the first partner as fallback.
  def target_agency(agency_id)
    ActsAsTenant.without_tenant do
      return Agency.where(id: agency_id, is_partner: true).first if agency_id.present?
      Agency.partners.find_by(slug: "HOS") || Agency.partners.order(:name).first || Agency.first
    end
  end

  # A family typed "phone or email" in one box on the landing. Route it to the
  # correct Patient field when we carry it into the chart.
  def split_contact(raw)
    s = raw.to_s.strip
    return [ nil, nil ] if s.empty?
    s.include?("@") ? [ nil, s ] : [ s, nil ]
  end

  def inquiry_json(i)
    {
      id:              i.id,
      first_name:      i.first_name,
      last_name:       i.last_name,
      dob:             i.dob,
      zip_prefix:      i.zip_prefix,
      contact:         i.contact,
      caregiver_phone: i.caregiver_phone,
      email:           i.email,
      diagnosis:       i.diagnosis,
      payer:           i.payer,
      requester_role:  i.requester_role,
      external_mrn:        i.external_mrn,
      referring_provider:  i.referring_provider,
      referring_provider_npi: i.referring_provider_npi,
      requested_service:   i.requested_service,
      reason_for_referral: i.reason_for_referral,
      urgency:             i.urgency,
      referral_date:       i.referral_date&.iso8601,
      external_referral_id: i.external_referral_id,
      question:        i.question,
      preferred_window: i.preferred_window_label,
      source_prompt:   i.source_prompt,
      is_general:      i.is_general,
      status:          i.status,
      created_at:      i.created_at.iso8601
    }
  end
end
