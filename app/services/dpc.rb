# Data at the Point of Care (DPC) — CMS's FHIR API that lets a treating
# Fee-for-Service provider pull a patient's Medicare claims. We use it to enrich
# the admission eval with a real diagnosis history (advisory; the RN confirms).
#
# Dormant until credentialed: every entry point no-ops unless `configured?`.
# Activation needs a DPC account + a registered keypair + patient attribution
# (see Dpc::Client). Until then this layer is inert and safe to ship.
module Dpc
  ENV_KEYS = %w[DPC_BASE_URL DPC_CLIENT_TOKEN DPC_PRIVATE_KEY].freeze

  def self.configured?
    ENV_KEYS.all? { |k| ENV[k].to_s.strip.present? }
  end

  def self.base_url
    ENV["DPC_BASE_URL"].to_s.chomp("/")
  end
end
