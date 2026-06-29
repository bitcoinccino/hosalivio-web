# Continuous Care interval (shift) charting. Clinician-only (visit RN / LPN /
# CNA). A chart stays :draft until electronically signed via Signatures::Apply,
# after which it's read-only.
class CcIntervalChartsController < ApplicationController
  before_action :authenticate_user!
  before_action :block_family
  before_action :set_patient, only: [ :index, :new, :create, :extract ]
  before_action :set_chart,   only: [ :show, :edit, :update, :sign ]

  def index
    with_tenant { @charts = @patient.cc_interval_charts.order(date_of_shift: :desc, created_at: :desc) }
  end

  def new
    with_tenant do
      @chart = @patient.cc_interval_charts.new(user: current_user, date_of_shift: Date.current)
      @chart.cc_vitals_records.build
      @chart.cc_poc_interventions.build
      @chart.cc_controlled_substance_counts.build
    end
  end

  # POST /patients/:patient_id/cc_interval_charts/extract — HosAlivio turns the
  # dictation into a prefilled DRAFT for review. Nothing is persisted here; the
  # clinician edits and submits #create, then signs.
  def extract
    with_tenant do
      attrs = Cc::ChartExtractor.call(
        patient: @patient, dictation: params[:dictation], role: current_user.role_names.first
      )
      @chart = @patient.cc_interval_charts.new(attrs.merge(user: current_user))
      @chart.date_of_shift ||= Date.current
      @dictation    = params[:dictation].to_s
      @ai_prefilled = true
      seed_blank_rows
      flash.now[:notice] = attrs.present? ? "HosAlivio drafted this from your dictation — review every field, then save." \
                                          : "Couldn't draft from that. Fill the chart in manually."
      render :new, status: :ok
    end
  end

  def create
    with_tenant do
      @chart = @patient.cc_interval_charts.new(chart_params)
      @chart.user = current_user
      if @chart.save
        redirect_to cc_interval_chart_path(@chart), status: :see_other,
                    notice: "Continuous Care chart saved as draft."
      else
        seed_blank_rows
        render :new, status: :unprocessable_entity
      end
    end
  end

  def show; end

  def edit
    redirect_to(cc_interval_chart_path(@chart), alert: signed_msg) and return if @chart.status_signed?
  end

  def update
    with_tenant do
      return redirect_to(cc_interval_chart_path(@chart), alert: signed_msg) if @chart.status_signed?
      if @chart.update(chart_params)
        redirect_to cc_interval_chart_path(@chart), status: :see_other,
                    notice: "Continuous Care chart updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  # POST /cc_interval_charts/:id/sign — apply the clinician e-signature and lock
  # the chart. Reuses the shared signature panel contract (apply_signature +
  # intent_confirmed) and the audit-grade Signatures::Apply chokepoint.
  def sign
    with_tenant do
      return redirect_to(cc_interval_chart_path(@chart), alert: "This chart is already signed.") if @chart.status_signed?
      norm  = ->(s) { s.to_s.strip.downcase.gsub(/\s+/, " ") }
      typed_ok = norm.call(params[:typed_name]) == norm.call(current_user.full_name) && params[:typed_name].present?
      unless params[:apply_signature] == "1" && params[:intent_confirmed] == "1" && typed_ok
        return redirect_to(cc_interval_chart_path(@chart), alert: "Confirm the attestation and type your full name to sign.")
      end
      Signatures::Apply.call(
        signable: @chart, user: current_user, request: request,
        method:   "cc_interval_sign",
        intent:   params[:intent_text].to_s.presence ||
                  "I attest this Continuous Care interval chart is accurate and complete."
      )
      @chart.update!(status: :signed)
      redirect_to cc_interval_chart_path(@chart), status: :see_other, notice: "Chart signed and locked."
    end
  end

  private

  def with_tenant(&block)
    ActsAsTenant.with_tenant(current_user.agency, &block)
  end

  def block_family
    redirect_to(root_path, alert: "Not available.") if current_user.family_access?
  end

  def signed_msg = "This chart is signed and can no longer be edited."

  def set_patient
    with_tenant { @patient = Patient.find(params[:patient_id]) }
  end

  def set_chart
    with_tenant do
      @chart   = CcIntervalChart.find(params[:id])
      @patient = @chart.patient
    end
  end

  # Re-build one empty row per section so a failed create still renders inputs.
  def seed_blank_rows
    @chart.cc_vitals_records.build              if @chart.cc_vitals_records.empty?
    @chart.cc_poc_interventions.build           if @chart.cc_poc_interventions.empty?
    @chart.cc_controlled_substance_counts.build if @chart.cc_controlled_substance_counts.empty?
  end

  def chart_params
    params.require(:cc_interval_chart).permit(
      :date_of_shift, :shift_start_time, :shift_end_time, :visit_id,
      :facility_or_ha_shift, :see_attached_addendum,
      :universal_precautions, :gown_or_apron, :face_shield_or_goggles, :mask,
      :n95_mask, :contact_isolation, :airborne_isolation, :droplet_isolation,
      cc_vitals_records_attributes: [
        :id, :recorded_at, :temperature, :pulse, :blood_pressure, :respiration,
        :intake_details, :output_diapers, :bowel_movement, :_destroy
      ],
      cc_poc_interventions_attributes: [
        :id, :ref_number, :symptom, :med_name_and_dose, :med_source,
        :initial_time, :post_time, :initial_level, :post_level, :response_to_care, :_destroy
      ],
      cc_controlled_substance_counts_attributes: [
        :id, :drug_name, :count_at_start, :count_at_end, :_destroy
      ]
    )
  end
end
