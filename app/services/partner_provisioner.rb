# Transactional create for a brand-new partner agency off the signup
# wizard. Takes the 3-step session hash collected by PartnersController
# and materializes it into real rows: one Agency, one Branch, one admin
# User (and optionally a placeholder MD User if the wizard supplied a
# separate MD email). Everything inside a single transaction so a
# partial failure rolls back the entire signup — no half-provisioned
# agencies.
#
# Usage:
#   PartnerProvisioner.call(state: session_state_hash)
#   # => Result(agency:, branch:, admin:, md:)
#
# Raises ActiveRecord::RecordInvalid on validation failure so the
# controller can render the form with the errors.

class PartnerProvisioner
  Result = Struct.new(:agency, :branch, :admin, :md, :demo_patients, keyword_init: true)

  def self.call(state:)
    new(state).call
  end

  def initialize(state)
    @s1 = state[:step1].to_h.with_indifferent_access
    @s2 = state[:step2].to_h.with_indifferent_access
    @s3 = state[:step3].to_h.with_indifferent_access
  end

  def call
    demo = nil
    ActiveRecord::Base.transaction do
      @agency = build_agency!
      ActsAsTenant.with_tenant(@agency) do
        @branch = build_branch!
        @admin  = build_admin_user!
        @md     = build_md_user! if @s3[:md_email].present?
        assign_branch_leadership!
      end
    end
    # Seed outside the provisioning transaction — if demo seeding fails
    # we still keep the agency. Admin can retry via admin UI later.
    demo = GoldenSeed.call(agency: @agency, branch: @branch, admin: @admin) if @s3[:seed_demo_patients]
    Result.new(agency: @agency, branch: @branch, admin: @admin, md: @md, demo_patients: demo)
  end

  private

  def build_agency!
    Agency.create!(
      name:                     @s1[:legal_name],
      dba_name:                 @s1[:dba_name].presence,
      slug:                     @s1[:slug].presence || derive_slug(@s1[:legal_name]),
      npi:                      @s1[:npi].presence,
      medicare_provider_number: @s1[:medicare_provider_number].presence,
      accreditation_body:       @s1[:accreditation_body].presence,
      administrator_name:       @s1[:administrator_name].presence,
      address_line1:            @s2[:address_line1].presence,
      city:                     @s2[:city].presence,
      state:                    @s2[:state].presence,
      zip:                      @s2[:zip].presence,
      phone:                    @s2[:phone].presence,
      service_area_zips:        (@s2[:service_area_zips] || []),
      after_hours_instructions: @s2[:after_hours_instructions].presence,
      mac_region:               @s3[:mac_region].presence,
      emr_system:               @s3[:emr_system].presence,
      pharmacy_partner:         @s3[:pharmacy_partner].presence,
      dme_partner:              @s3[:dme_partner].presence,
      billing_tier:             "starter",
      is_partner:               true,
      active:                   true
    )
  end

  def build_branch!
    Branch.create!(
      agency:                @agency,
      name:                  @s2[:branch_name],
      address_line1:         @s2[:address_line1].presence,
      address_line2:         @s2[:address_line2].presence,
      city:                  @s2[:city],
      state:                 @s2[:state],
      zip:                   @s2[:zip],
      phone:                 @s2[:phone],
      timezone:              @s2[:timezone].presence || "America/New_York",
      service_area_zips:     (@s2[:service_area_zips] || []),
      after_hours_phone:     @s2[:after_hours_phone].presence,
      active:                true
    )
  end

  def build_admin_user!
    user = User.create!(
      agency:    @agency,
      branch:    @branch,
      email:     @s3[:admin_email],
      full_name: @s1[:administrator_name].presence || @s3[:admin_email].split("@").first.titleize,
      active:    true,
      password:              @s3[:admin_password],
      password_confirmation: @s3[:admin_password]
    )
    assign_role!(user, "admin")
    user
  end

  # Placeholder MD User so the Branch can link medical_director_id and
  # the Pre-Admit Eval has an evaluator to reference. Marked inactive and
  # given a random password — the admin is expected to re-invite the MD
  # properly via the team-members UI later.
  def build_md_user!
    pw = SecureRandom.hex(16)
    user = User.create!(
      agency:                @agency,
      branch:                @branch,
      email:                 @s3[:md_email],
      full_name:             @s3[:md_name].presence || "Medical Director",
      active:                false,
      password:              pw,
      password_confirmation: pw
    )
    # Copy npi if the User model carries it; skip gracefully otherwise.
    if user.respond_to?(:npi) && user.respond_to?(:npi=)
      user.update(npi: @s3[:md_npi].presence)
    end
    assign_role!(user, "md")
    user
  end

  def assign_branch_leadership!
    updates = {}
    updates[:medical_director_id] = @md.id if @md
    # DON is captured as a name only (no email collected in the wizard
    # currently), so we don't link a User. Store the name on the Agency
    # as a placeholder — admin can invite them properly later.
    @branch.update!(updates) if updates.any?
  end

  def assign_role!(user, role_name)
    role = Role.find_or_create_by!(name: role_name)
    UserRole.find_or_create_by!(user: user, role: role)
  end

  def derive_slug(name)
    base = name.to_s.upcase.gsub(/[^A-Z0-9]/, "")[0, 6]
    return "AGY#{rand(100..999)}" if base.length < 2
    base
  end
end
