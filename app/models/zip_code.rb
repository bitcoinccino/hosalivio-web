class ZipCode < ApplicationRecord
  # Offline ZIP -> city/state/county reference for address autofill.

  validates :zip, presence: true, uniqueness: true

  before_validation { self.zip = zip.to_s.strip.rjust(5, "0") if zip.present? }

  def self.lookup(zip)
    z = zip.to_s.strip
    return nil unless z =~ /\A\d{5}\z/
    find_by(zip: z)
  end

  def as_json_payload
    { zip: zip, city: city, state: state, county: county }
  end
end
