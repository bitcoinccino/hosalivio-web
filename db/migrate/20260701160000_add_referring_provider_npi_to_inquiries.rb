class AddReferringProviderNpiToInquiries < ActiveRecord::Migration[8.1]
  def change
    # NPI is a public provider identifier (searchable in NPPES), not PHI — so it
    # stays in the clear, unlike the other referral fields.
    add_column :inquiries, :referring_provider_npi, :string
  end
end
