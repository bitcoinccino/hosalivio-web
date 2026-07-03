class AddIntakeExtrasToPatients < ActiveRecord::Migration[8.1]
  def change
    # Loose, rarely-queried intake fields (marital status, race/ethnicity,
    # attending physician, care locations, veteran flags, referral source,
    # insurance verification) held as an encrypted JSON blob rather than 30
    # columns. PII/PHI, so encrypted at rest by the model.
    add_column :patients, :intake_extras, :text
  end
end
