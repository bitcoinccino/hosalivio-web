# Seeds three realistic hospice demo patients (Maria, John, Liam) into a
# specific agency + branch. Called right after partner provisioning so
# the new admin's dashboard is alive on first login, not a blank slate.
#
# Each patient is a different clinical profile so the admin can explore
# different agent paths:
#   Maria  — 83F, end-stage CHF, DNR, Spanish-preferred (the canonical case)
#   John   — 76M, lung cancer, on active pain crisis path (tests MD agent)
#   Liam   — 9M, pediatric neuromuscular (tests chaplain + SW + family distress)
#
# All three share the same assigned RN/MD/SW/Chaplain — whichever clinical
# users already exist in the agency. Idempotent by MRN so re-running is
# safe during development.
#
#   GoldenSeed.call(agency: agency, branch: branch, admin: admin)

class GoldenSeed
  def self.call(agency:, branch:, admin:)
    new(agency: agency, branch: branch, admin: admin).call
  end

  def initialize(agency:, branch:, admin:)
    @agency = agency
    @branch = branch
    @admin  = admin
  end

  def call
    ActsAsTenant.with_tenant(@agency) do
      clinicians = ensure_clinical_team
      [maria(clinicians), john(clinicians), liam(clinicians)].compact
    end
  end

  private

  # Find any existing clinicians in the agency by role, or fall back to
  # the admin so Patient.assigned_* can still reference a real user.
  def ensure_clinical_team
    {
      rn:       find_by_role("rn")            || @admin,
      md:       find_by_role("md")            || @admin,
      sw:       find_by_role("social_worker") || @admin,
      chaplain: find_by_role("chaplain")      || @admin
    }
  end

  def find_by_role(name)
    User.joins(user_roles: :role)
        .where(agency: @agency, active: true, roles: { name: name })
        .first
  end

  def maria(team)
    upsert_patient(
      mrn: "HOS-DEMO-MARIA",
      attrs: {
        first_name: "Maria", last_name: "Alvarez",
        dob: Date.new(1942, 9, 18),
        gender: "F", preferred_language: "es",
        address_line1: "422 Sunset Dr", city: @branch.city, state: @branch.state, zip: @branch.zip,
        phone: "555-0199",
        primary_diagnosis: "End-stage CHF (ICD-10 I50.84)",
        secondary_diagnoses: "COPD, T2DM, CKD stage 4",
        hospice_election_date: 30.days.ago.to_date,
        benefit_period: :bp1_90,
        cert_period_start: 30.days.ago.to_date,
        cert_period_end:   60.days.from_now.to_date,
        status: :active, code_status: :dnr,
        advance_directive_on_file: true, polst_on_file: true,
        caregiver_name: "Carlos Alvarez (son)", caregiver_phone: "555-0188",
        branch: @branch,
        assigned_rn: team[:rn], assigned_md: team[:md],
        assigned_sw: team[:sw], assigned_chaplain: team[:chaplain]
      }
    )
  end

  def john(team)
    upsert_patient(
      mrn: "HOS-DEMO-JOHN",
      attrs: {
        first_name: "John", last_name: "Okonkwo",
        dob: Date.new(1949, 3, 4),
        gender: "M", preferred_language: "en",
        address_line1: "18 Oak Lane", city: @branch.city, state: @branch.state, zip: @branch.zip,
        phone: "555-0143",
        primary_diagnosis: "Metastatic NSCLC (ICD-10 C34.92)",
        secondary_diagnoses: "Chronic pain, depression",
        hospice_election_date: 12.days.ago.to_date,
        benefit_period: :bp1_90,
        cert_period_start: 12.days.ago.to_date,
        cert_period_end:   78.days.from_now.to_date,
        status: :active, code_status: :dnr_dni,
        advance_directive_on_file: true, polst_on_file: false,
        caregiver_name: "Adaeze Okonkwo (wife)", caregiver_phone: "555-0144",
        branch: @branch,
        assigned_rn: team[:rn], assigned_md: team[:md],
        assigned_sw: team[:sw], assigned_chaplain: team[:chaplain]
      }
    )
  end

  def liam(team)
    upsert_patient(
      mrn: "HOS-DEMO-LIAM",
      attrs: {
        first_name: "Liam", last_name: "Sullivan",
        dob: Date.new(2016, 11, 22),
        gender: "M", preferred_language: "en",
        address_line1: "77 Linden Ave", city: @branch.city, state: @branch.state, zip: @branch.zip,
        phone: "555-0166",
        primary_diagnosis: "Spinal muscular atrophy type 1 (ICD-10 G12.0)",
        secondary_diagnoses: "Respiratory insufficiency, GT-fed",
        hospice_election_date: 45.days.ago.to_date,
        benefit_period: :bp1_90,
        cert_period_start: 45.days.ago.to_date,
        cert_period_end:   45.days.from_now.to_date,
        status: :active, code_status: :full_code,
        advance_directive_on_file: false, polst_on_file: false,
        caregiver_name: "Aoife Sullivan (mother)", caregiver_phone: "555-0167",
        branch: @branch,
        assigned_rn: team[:rn], assigned_md: team[:md],
        assigned_sw: team[:sw], assigned_chaplain: team[:chaplain]
      }
    )
  end

  def upsert_patient(mrn:, attrs:)
    # Scope MRN uniqueness to the agency so two partners can each have
    # their own HOS-DEMO-MARIA without colliding.
    prefixed_mrn = "#{@agency.slug}-#{mrn}"
    patient = Patient.find_or_initialize_by(agency: @agency, mrn: prefixed_mrn)
    return patient if patient.persisted?
    patient.assign_attributes(attrs)
    patient.save!
    patient
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[GoldenSeed] skipping #{mrn} for #{@agency.slug}: #{e.record.errors.full_messages.to_sentence}")
    nil
  end
end
