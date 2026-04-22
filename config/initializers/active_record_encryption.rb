# Active Record encryption keys.
#
# In development/test we read from ENV with a dev fallback so the app boots
# without needing `rails credentials:edit`. In production, set the three ENV
# vars (or move to Rails credentials) and never commit the real values.
#
# Generate fresh keys with:  bin/rails db:encryption:init

if Rails.env.development? || Rails.env.test?
  Rails.application.config.active_record.encryption.primary_key =
    ENV.fetch("AR_ENCRYPTION_PRIMARY_KEY", "CexIDO7f2l5YC3IzpkmKM45NfaP0HuPI")
  Rails.application.config.active_record.encryption.deterministic_key =
    ENV.fetch("AR_ENCRYPTION_DETERMINISTIC_KEY", "zrm6h1P5CvnolpBtLAl6enh5TuUSwZIi")
  Rails.application.config.active_record.encryption.key_derivation_salt =
    ENV.fetch("AR_ENCRYPTION_KEY_DERIVATION_SALT", "HUUpjWEJn5iOXOT0Nwj81HPjqZTVPFBI")
else
  # Production: require real values from ENV. No fallback.
  Rails.application.config.active_record.encryption.primary_key =
    ENV.fetch("AR_ENCRYPTION_PRIMARY_KEY")
  Rails.application.config.active_record.encryption.deterministic_key =
    ENV.fetch("AR_ENCRYPTION_DETERMINISTIC_KEY")
  Rails.application.config.active_record.encryption.key_derivation_salt =
    ENV.fetch("AR_ENCRYPTION_KEY_DERIVATION_SALT")
end
