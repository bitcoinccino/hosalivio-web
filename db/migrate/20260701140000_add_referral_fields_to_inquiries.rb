class AddReferralFieldsToInquiries < ActiveRecord::Migration[8.1]
  def change
    # Encrypted at rest by the model (PII/PHI): external MRN, referring provider
    # name, the clinical reason, and the raw inbound FHIR payload (audit blob).
    add_column :inquiries, :external_mrn,        :string
    add_column :inquiries, :referring_provider,  :string
    add_column :inquiries, :reason_for_referral, :text
    # The raw inbound bundle is full PHI (name, DOB, MRN, diagnosis), so it is
    # an encrypted :text blob — NOT jsonb. jsonb would leave PHI readable at
    # rest, inconsistent with every other encrypted field here. It's an audit
    # blob, never queried, so losing jsonb query support costs nothing.
    add_column :inquiries, :raw_fhir_payload,    :text

    # Non-sensitive routing/scheduling metadata — stays in the clear.
    add_column :inquiries, :requested_service,   :string
    add_column :inquiries, :urgency,             :string
    add_column :inquiries, :referral_date,       :datetime
    add_column :inquiries, :desired_date,        :datetime

    # Sender's business identifier — used to dedupe re-sent referrals. Plain so
    # it's queryable; opaque, not PHI.
    add_column :inquiries, :external_referral_id, :string
    add_index  :inquiries, [ :agency_id, :external_referral_id ],
               name: "index_inquiries_on_agency_and_external_referral_id"
  end
end
