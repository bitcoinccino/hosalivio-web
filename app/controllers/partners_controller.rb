# Three-step self-serve partner signup wizard.
#
# Wizard state lives in session[:partner_signup] until the user hits
# `complete` — only then do we persist an Agency + first Branch + admin
# User. This means closing the browser mid-wizard leaves no orphaned
# rows, and the user can go back and forth between steps without the
# database lighting up.
#
# Step 1 — Identity & Compliance     (Agency-level legal anchor)
# Step 2 — First Branch & Operations (Branch-level ops + after-hours)
# Step 3 — Vendors + Admin login     (Agent wiring + first User)
#
# Route map (see config/routes.rb):
#   GET   /partners/new       → step 1 form
#   POST  /partners           → save step 1, redirect to step 2
#   GET   /partners/step_2    → step 2 form
#   POST  /partners/step_2    → save step 2, redirect to step 3
#   GET   /partners/step_3    → step 3 form
#   POST  /partners/complete  → transaction-create everything, redirect
#                               to /users/sign_in with instructions.

class PartnersController < ApplicationController
  # The wizard is public — no authentication required. Leaving
  # skip_before_action off since ApplicationController doesn't currently
  # force authenticate_user! globally.

  SESSION_KEY = :partner_signup

  def new
    @form = wizard_state
  end

  def create
    store(:step1, sanitize_step1(params))
    if step1_valid?(wizard_state[:step1])
      redirect_to partner_step_2_path
    else
      @form = wizard_state
      flash.now[:alert] = "Please fill in the required fields."
      render :new, status: :unprocessable_entity
    end
  end

  def step_2
    redirect_to(new_partner_path) and return if wizard_state[:step1].blank?
    @form = wizard_state
  end

  def save_step_2
    store(:step2, sanitize_step2(params))
    if step2_valid?(wizard_state[:step2])
      redirect_to partner_step_3_path
    else
      @form = wizard_state
      flash.now[:alert] = "Please fill in the required branch fields."
      render :step_2, status: :unprocessable_entity
    end
  end

  def step_3
    redirect_to(new_partner_path) and return if wizard_state[:step1].blank?
    redirect_to(partner_step_2_path) and return if wizard_state[:step2].blank?
    @form = wizard_state
  end

  def complete
    store(:step3, sanitize_step3(params))
    state = wizard_state
    unless step3_valid?(state[:step3])
      @form = state
      flash.now[:alert] = "Please fill in your admin email and password."
      render :step_3, status: :unprocessable_entity
      return
    end

    begin
      result = PartnerProvisioner.call(state: state)
    rescue ActiveRecord::RecordInvalid => e
      @form = state
      flash.now[:alert] = "Could not create partner: #{e.record.errors.full_messages.to_sentence}"
      render :step_3, status: :unprocessable_entity
      return
    end

    reset_wizard_state
    flash[:notice] = "Partner '#{result.agency.name}' created. " \
                     "Sign in as #{result.admin.email} to start exploring."
    redirect_to new_user_session_path
  end

  private

  # ── wizard state helpers ─────────────────────────────────────────

  def wizard_state
    session[SESSION_KEY] ||= {}
    session[SESSION_KEY].with_indifferent_access
  end

  def store(step_key, data)
    session[SESSION_KEY] ||= {}
    session[SESSION_KEY] = session[SESSION_KEY].merge(step_key.to_s => data)
  end

  def reset_wizard_state
    session.delete(SESSION_KEY)
  end

  # ── sanitizers ───────────────────────────────────────────────────

  def sanitize_step1(p)
    {
      legal_name:          p[:legal_name].to_s.strip,
      dba_name:            p[:dba_name].to_s.strip,
      slug:                p[:slug].to_s.strip.upcase,
      npi:                 p[:npi].to_s.strip,
      medicare_provider_number: p[:medicare_provider_number].to_s.strip,
      state_license_number:     p[:state_license_number].to_s.strip,
      accreditation_body:  p[:accreditation_body].to_s.strip.presence,
      administrator_name:  p[:administrator_name].to_s.strip
    }
  end

  def sanitize_step2(p)
    {
      branch_name:             p[:branch_name].to_s.strip,
      address_line1:           p[:address_line1].to_s.strip,
      city:                    p[:city].to_s.strip,
      state:                   p[:state].to_s.strip.upcase,
      zip:                     p[:zip].to_s.strip,
      phone:                   p[:phone].to_s.strip,
      timezone:                p[:timezone].presence || "America/New_York",
      service_area_zips:       p[:service_area_zips].to_s.split(/[\s,]+/).compact_blank,
      after_hours_phone:       p[:after_hours_phone].to_s.strip,
      after_hours_instructions: p[:after_hours_instructions].to_s.strip
    }
  end

  def sanitize_step3(p)
    {
      mac_region:              p[:mac_region].to_s.strip.presence,
      emr_system:              p[:emr_system].to_s.strip.presence,
      pharmacy_partner:        p[:pharmacy_partner].to_s.strip.presence,
      dme_partner:             p[:dme_partner].to_s.strip.presence,
      don_name:                p[:don_name].to_s.strip,
      md_name:                 p[:md_name].to_s.strip,
      md_npi:                  p[:md_npi].to_s.strip,
      md_email:                p[:md_email].to_s.strip.downcase,
      admin_email:             p[:admin_email].to_s.strip.downcase,
      admin_password:          p[:admin_password].to_s,
      seed_demo_patients:      ActiveModel::Type::Boolean.new.cast(p[:seed_demo_patients])
    }
  end

  # ── validators (cheap, not full-model validation) ────────────────

  def step1_valid?(s1)
    return false unless s1
    s1[:legal_name].to_s.present? && s1[:slug].to_s.match?(/\A[A-Z0-9]{2,6}\z/)
  end

  def step2_valid?(s2)
    return false unless s2
    s2[:branch_name].to_s.present? && s2[:city].to_s.present? && s2[:state].to_s.length == 2
  end

  def step3_valid?(s3)
    return false unless s3
    s3[:admin_email].to_s.match?(URI::MailTo::EMAIL_REGEXP) && s3[:admin_password].to_s.length >= 8
  end
end
