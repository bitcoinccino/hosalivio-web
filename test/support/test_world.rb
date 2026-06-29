require "base64"
require "stringio"

# Builders for the minimal multi-tenant world controller/request tests need:
# an agency, role-assigned users (optionally with a registered e-signature),
# patients, and admission evals. Everything is created inside the agency tenant
# so acts_as_tenant scoping behaves exactly as it does in a real request.
module TestWorld
  # 1x1 transparent PNG — a valid, tiny signature image for ActiveStorage.
  SIGNATURE_PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
  ).freeze

  # Slug must match /\A[A-Z0-9]{2,6}\z/ and be unique.
  def create_agency(name: "Test Hospice", slug: SecureRandom.alphanumeric(5).upcase)
    Agency.create!(name: name, slug: slug)
  end

  # Wrap any block of record creation in the agency tenant.
  def in_tenant(agency, &block) = ActsAsTenant.with_tenant(agency, &block)

  def create_user(agency:, full_name:, roles: [], registered_signature: false,
                  family_access: false, patient: nil)
    in_tenant(agency) do
      user = User.create!(
        email:         "#{rand_suffix}@test.dev",
        password:      "password123!",
        full_name:     full_name,
        timezone:      "America/New_York",
        agency:        agency,
        family_access: family_access,
        patient:       patient
      )
      Array(roles).each { |r| user.roles << find_or_create_role(r) }
      register_signature(user) if registered_signature
      user
    end
  end

  def create_patient(agency:, first_name: "Maria", last_name: "Gonzalez",
                     assigned_md: nil, assigned_rn: nil, assigned_visit_rn: nil)
    in_tenant(agency) do
      Patient.create!(agency: agency, first_name: first_name, last_name: last_name,
                      dob: Date.new(1940, 1, 1), mrn: "MRN#{rand_suffix(4)}",
                      assigned_md: assigned_md, assigned_rn: assigned_rn,
                      assigned_visit_rn: assigned_visit_rn)
    end
  end

  def create_eval(agency:, patient:, evaluator: nil)
    in_tenant(agency) do
      PreAdmitEval.create!(agency: agency, patient: patient, evaluator: evaluator,
                           raw_json: { "pre_admit_eval" => {} })
    end
  end

  def find_or_create_role(name)
    Role.find_or_create_by!(name: name.to_s) { |r| r.label = name.to_s.titleize }
  end

  # Full set of valid signature params the Signatures::Gate expects.
  def signature_params(user, extra = {})
    { apply_signature: "1", intent_confirmed: "1", typed_name: user.full_name }.merge(extra)
  end

  private

  def register_signature(user)
    user.signature.attach(io: StringIO.new(SIGNATURE_PNG), filename: "sig.png", content_type: "image/png")
    user.update!(signature_registered_at: Time.current)
  end

  def rand_suffix(bytes = 3) = SecureRandom.hex(bytes)
end
