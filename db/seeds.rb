# HosAlivio demo seed — one agency, every role, a demo patient, a few events.
# Idempotent: re-running overwrites sensibly.

puts "== Seeding roles =="
ROLES = {
  "admin"         => "System Admin",
  "rn"            => "Registered Nurse",
  "lpn"           => "Licensed Practical Nurse",
  "md"            => "Hospice Physician",
  "admissions"    => "Admissions Coordinator",
  "dme"           => "DME Coordinator",
  "pharmacy"      => "Pharmacy Coordinator",
  "insurance"     => "Insurance Coordinator",
  "billing"       => "Billing",
  "chaplain"      => "Chaplain",
  "social_worker" => "Social Worker",
  "aide"          => "Hospice Aide",
  "family"        => "Family Portal"
}
ROLES.each { |name, label| Role.find_or_create_by!(name: name) { |r| r.label = label } }
puts "   #{Role.count} roles"

puts "== Seeding demo agency =="
agency = ActsAsTenant.without_tenant do
  Agency.find_or_create_by!(slug: "HOS") do |a|
    a.name                     = "HosAlivio Demo Hospice"
    a.address_line1            = "1 Comfort Way"
    a.city                     = "Miami"
    a.state                    = "FL"
    a.zip                      = "33101"
    a.phone                    = "305-555-0100"
    a.npi                      = "1234567890"
    a.medicare_provider_number = "FL-1001"
    a.billing_tier             = :pro
  end
end
puts "   #{agency.name} (#{agency.slug})"

ActsAsTenant.with_tenant(agency) do
  puts "== Seeding users (one per role) =="
  # AI agent personas are named by ROLE TITLE (not personal names) so they read
  # clearly as the per-role agent — and don't get mistaken for real clinicians
  # once humans are added. "System Admin" and "HosAlivio" stay as system personas.
  # `name` is the primary ROLE TITLE (full_name); `friendly` is the optional
  # personal name shown as a secondary label. System personas (admin,
  # admissions) have no friendly name.
  USERS = {
    "admin"         => { email: "admin@hosalivio.com",      name: "System Admin" },
    "rn"            => { email: "rn@hosalivio.com",         name: "Admitting RN",        friendly: "Pascal Benoit" },
    "md"            => { email: "md@hosalivio.com",         name: "Medical Director",    friendly: "Dr. Esther Nguyen" },
    "admissions"    => { email: "admissions@hosalivio.com", name: "HosAlivio" },
    "dme"           => { email: "dme@hosalivio.com",        name: "DME Coordinator",     friendly: "Marcus Brown" },
    "pharmacy"      => { email: "pharmacy@hosalivio.com",   name: "Pharmacy",            friendly: "Simone Wallace" },
    "insurance"     => { email: "insurance@hosalivio.com",  name: "Insurance",           friendly: "Kendra Foster" },
    "billing"       => { email: "billing@hosalivio.com",    name: "Billing",             friendly: "Wolfwide Smith" },
    "chaplain"      => { email: "chaplain@hosalivio.com",   name: "Chaplain",            friendly: "Geoginio Rousseau" },
    "social_worker" => { email: "sw@hosalivio.com",         name: "Social Worker",       friendly: "Nickla Paul" },
    "aide"          => { email: "aide@hosalivio.com",       name: "Home Health Aide",    friendly: "Flore Dupont" }
  }

  USERS.each do |role_name, info|
    u = User.find_or_initialize_by(email: info[:email])
    u.full_name     = info[:name]
    u.friendly_name = info[:friendly]
    u.agency    = agency
    u.password  = "hello123"
    u.save!
    role = Role.find_by!(name: role_name)
    UserRole.find_or_create_by!(user: u, role: role, agency: agency)
  end
  puts "   #{User.where(agency: agency).count} users, #{UserRole.count} role assignments"

  puts "== Seeding demo patient =="
  rn  = User.find_by!(email: "rn@hosalivio.com")
  md  = User.find_by!(email: "md@hosalivio.com")
  sw  = User.find_by!(email: "sw@hosalivio.com")
  cpl = User.find_by!(email: "chaplain@hosalivio.com")

  patient = Patient.find_or_initialize_by(agency: agency, mrn: "HOS-00001")
  if patient.new_record?
    patient.assign_attributes(
      first_name: "Maria", last_name: "Alvarez",
      dob: Date.new(1942, 9, 18),
      gender: "F", preferred_language: "es",
      address_line1: "422 Sunset Dr", city: "Hialeah", state: "FL", zip: "33012",
      phone: "305-555-0199",
      primary_diagnosis: "End-stage CHF (ICD-10 I50.84)",
      secondary_diagnoses: "COPD, T2DM, CKD stage 4",
      allergies: [ { substance: "penicillin", reaction: "rash" } ],
      hospice_election_date: 30.days.ago.to_date,
      benefit_period: :bp1_90,
      cert_period_start: 30.days.ago.to_date,
      cert_period_end:   60.days.from_now.to_date,
      status: :active,
      code_status: :dnr,
      advance_directive_on_file: true,
      polst_on_file: true,
      caregiver_name: "Carlos Alvarez (son)",
      caregiver_phone: "305-555-0188",
      assigned_rn: rn, assigned_md: md, assigned_sw: sw, assigned_chaplain: cpl
    )
    patient.save!
  end
  puts "   Patient: #{patient.mrn} — #{patient.full_name}"

  puts "== Seeding example visit + med order =="
  unless patient.visits.any?
    Visit.create!(agency: agency, patient: patient, user: rn,
                  discipline: :rn, visit_type: :routine,
                  scheduled_at: 2.days.ago, started_at: 2.days.ago, ended_at: 2.days.ago + 45.minutes,
                  narrative: "Patient resting comfortably, no acute distress.",
                  vitals: { temp: 98.2, bp: "128/76", pulse: 88, resp: 18, o2: 95 },
                  pain_score: 2, billable: true, visit_code: "G0299")
  end

  unless patient.medication_orders.any?
    morphine = MedicationOrder.create!(
      agency: agency, patient: patient, prescribed_by: md,
      drug_name: "Morphine Sulfate", dose: "5mg", route: :sl,
      frequency: "q4h prn", prn: true, prn_indication: "pain or dyspnea",
      start_date: Date.current, status: :active
    )
    MedicationOrder.create!(
      agency: agency, patient: patient, prescribed_by: md,
      drug_name: "Lorazepam", dose: "0.5mg", route: :sl,
      frequency: "q6h prn", prn: true, prn_indication: "anxiety",
      start_date: Date.current, status: :active
    )

    # A recent dose so the timeline shows a real history + next-due calculation
    MedicationLog.create!(
      agency: agency, medication_order: morphine, administered_by: rn,
      administered_at: 2.hours.ago, dose_given: "5mg",
      effective: true, source: :home_supply
    )
  end

  # Seed a few extra vitals visits so the sparklines trend rather than flat-line
  if patient.visits.count < 4
    base = 3
    4.times do |i|
      Visit.create!(
        agency: agency, patient: patient, user: rn,
        discipline: :rn, visit_type: :routine,
        scheduled_at: (base - i).days.ago,
        started_at:   (base - i).days.ago,
        ended_at:     (base - i).days.ago + 30.minutes,
        narrative: "Routine check — patient stable.",
        vitals: {
          temp:  (97.6 + rand(-2..4) * 0.2).round(1),
          bp:    "#{120 + rand(-10..15)}/#{70 + rand(-5..10)}",
          pulse: 84 + rand(-6..10),
          resp:  18 + rand(-2..3),
          o2:    [ 94, 95, 96, 93, 97 ].sample
        },
        pain_score: [ 2, 3, 2, 4, 3 ].sample,
        billable: true, visit_code: "G0299"
      )
    end
  end

  # Family portal user — for login-gated /patients/:id/chat
  family_user = User.find_or_initialize_by(email: "family@hosalivio.com")
  family_user.full_name     = "Carlos Alvarez (son of #{patient.first_name})"
  family_user.agency        = agency
  family_user.family_access = true
  family_user.patient       = patient
  family_user.password      = "hello123"
  family_user.save!
  UserRole.find_or_create_by!(user: family_user, role: Role.find_by!(name: "family"), agency: agency)
  puts "   Family user: #{family_user.email} (scoped to patient #{patient.mrn})"
end

puts ""
puts "== Seeding partner agencies (directory on landing page) =="
PARTNERS = [
  {
    slug: "SERENE", name: "Serenity Pines Hospice",
    city: "Jacksonville", state: "FL", zip: "32202",
    emoji: "🌲", hero_color: "#2F6F4E",
    bio: "Twenty-three years of dementia and Alzheimer's specialization. Caregiver retreats and family-education focused.",
    specialties: %w[dementia_care general_hospice], insurance_accepted: %w[medicare medicaid private],
    languages: %w[en es], service_area_zips: %w[322 321 320], response_sla_hours: 6
  },
  {
    slug: "COMFSH", name: "Comfort Shore Hospice",
    city: "Tampa", state: "FL", zip: "33602",
    emoji: "🌊", hero_color: "#2B4A7A",
    bio: "Full-service hospice on the Gulf Coast. 24/7 in-home nursing, comfort kits within 4 hours.",
    specialties: %w[general_hospice cardiac oncology], insurance_accepted: %w[medicare medicaid private selfpay],
    languages: %w[en es], service_area_zips: %w[336 337 335], response_sla_hours: 4
  },
  {
    slug: "VETPAS", name: "Veterans Passage",
    city: "Orlando", state: "FL", zip: "32801",
    emoji: "🎖️", hero_color: "#8B5A2B",
    bio: "Hospice by veterans, for veterans. Trained in combat-related PTSD, service-connected illness, and VA paperwork.",
    specialties: %w[veterans general_hospice cardiac], insurance_accepted: %w[medicare va private],
    languages: %w[en], service_area_zips: %w[328 327 326], response_sla_hours: 12
  },
  {
    slug: "MERCY", name: "Mercy Home Hospice",
    city: "Orlando", state: "FL", zip: "32804",
    emoji: "🕊️", hero_color: "#7A4A8C",
    bio: "Central Florida's pediatric and young-adult specialist. Concurrent curative care model for kids on Medicaid.",
    specialties: %w[pediatric general_hospice palliative_bridge], insurance_accepted: %w[medicare medicaid private],
    languages: %w[en es], service_area_zips: %w[328], response_sla_hours: 2
  },
  {
    slug: "COASTL", name: "Coastal Compassion",
    city: "Fort Lauderdale", state: "FL", zip: "33301",
    emoji: "🌴", hero_color: "#D97757",
    bio: "Bilingual team fluent in Spanish, Haitian Creole, and Portuguese. Broward and Palm Beach coverage.",
    specialties: %w[general_hospice oncology], insurance_accepted: %w[medicare medicaid private],
    languages: %w[en es ht pt], service_area_zips: %w[333 334], response_sla_hours: 6
  },
  {
    slug: "SNSTLT", name: "Sunset Light Hospice",
    city: "Miami", state: "FL", zip: "33133",
    emoji: "🌅", hero_color: "#C1403A",
    bio: "LGBTQ+ affirming hospice. Chosen-family care plans, equitable bereavement, inclusive chaplaincy.",
    specialties: %w[lgbtq_affirming general_hospice oncology], insurance_accepted: %w[medicare private],
    languages: %w[en es], service_area_zips: %w[331], response_sla_hours: 6
  },
  {
    slug: "HLANDH", name: "Heartland Home Hospice",
    city: "Gainesville", state: "FL", zip: "32601",
    emoji: "🌾", hero_color: "#AD7340",
    bio: "Rural and small-town coverage across North-Central Florida. Telehealth and home-visit hybrid.",
    specialties: %w[rural_coverage general_hospice cardiac], insurance_accepted: %w[medicare medicaid private],
    languages: %w[en], service_area_zips: %w[326 325], response_sla_hours: 12
  }
].freeze

ActsAsTenant.without_tenant do
  PARTNERS.each do |attrs|
    a = Agency.find_or_initialize_by(slug: attrs[:slug])
    a.assign_attributes(
      name: attrs[:name],
      city: attrs[:city], state: attrs[:state], zip: attrs[:zip],
      bio: attrs[:bio], emoji: attrs[:emoji], hero_color: attrs[:hero_color],
      specialties: attrs[:specialties],
      insurance_accepted: attrs[:insurance_accepted],
      languages: attrs[:languages],
      service_area_zips: attrs[:service_area_zips],
      response_sla_hours: attrs[:response_sla_hours],
      billing_tier: :starter, is_partner: true, accepting_referrals: true, active: true
    )
    a.save!
  end

  # Flip the demo agency to also be listable (useful for screenshots)
  demo = Agency.find_by(slug: "HOS")
  if demo
    demo.update!(
      bio: "HosAlivio flagship demo agency. Live chat, real-time clinical dashboard, full-team IDG support.",
      emoji: "❤️‍🩹", hero_color: "#D97757",
      specialties: %w[general_hospice cardiac dementia_care],
      insurance_accepted: %w[medicare medicaid private],
      languages: %w[en es],
      service_area_zips: %w[331 330],
      is_partner: true, accepting_referrals: true,
      response_sla_hours: 2
    )
  end
end
puts "   #{Agency.where(is_partner: true).count} partner agencies listed"

puts ""
puts "== Seeding one admissions coordinator per partner agency =="
admissions_role = Role.find_by!(name: "admissions")
matrix = []
ActsAsTenant.without_tenant do
  Agency.where(is_partner: true).order(:name).each do |a|
    email = "partner@#{a.slug.downcase}.com"
    ActsAsTenant.with_tenant(a) do
      u = User.find_or_initialize_by(email: email)
      u.full_name = "#{a.name} Partner"
      u.agency    = a
      u.timezone  = "America/New_York"
      u.password  = "hello123"
      u.save!
      UserRole.find_or_create_by!(user: u, role: admissions_role, agency: a)
    end
    matrix << "   #{email.ljust(38)} → #{a.name}"
  end
end
puts matrix.join("\n")

puts ""
puts "== Done. =="
puts "Demo credentials: any @hosalivio.com email + password 'hello123'"
puts ""
puts "To print JWT tokens for agents:  bin/rails hosalivio:tokens"
