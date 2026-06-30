class AddIntakeFieldsToInquiries < ActiveRecord::Migration[8.1]
  def change
    # All hold PII/PHI and are encrypted at rest by the Inquiry model, so they
    # are plain string columns (no indexes — never queried in the clear).
    # dob is a string (not :date) because encrypted attributes serialize text.
    add_column :inquiries, :last_name,       :string
    add_column :inquiries, :dob,             :string
    add_column :inquiries, :caregiver_phone, :string
    add_column :inquiries, :email,           :string
    add_column :inquiries, :diagnosis,       :string

    # Who is submitting (caregiver/family vs. a referring clinician). A
    # low-sensitivity category, not PII, so it stays in the clear — useful for
    # triage and routing. Distinct from routed_to_role (who it's routed TO).
    add_column :inquiries, :requester_role,  :string
  end
end
