class Icd10Explanation < ApplicationRecord
  has_paper_trail

  # ICD-10-CM pattern: one letter, two digits, optional .subcode(1-4 chars).
  # Accepts "C50.9", "G20", "U07.1" (COVID-19), etc.
  CODE_FORMAT = /\A[A-Z]\d{2}(?:\.\w{1,4})?\z/

  validates :code, presence: true, uniqueness: { case_sensitive: false }, format: { with: CODE_FORMAT }
  validates :simple_description, presence: true

  before_validation :upcase_code

  # Lookup with soft fallback: try exact, then the base code without the decimal.
  # e.g. "C50.911" -> if not in table, try "C50.9" or "C50".
  def self.lookup(code)
    return nil if code.blank?
    norm = code.to_s.upcase.strip
    find_by(code: norm) || find_by(code: norm.split(".").first) || broader(norm)
  end

  def self.broader(norm)
    return nil unless norm.include?(".")
    base, tail = norm.split(".", 2)
    while tail.length > 1
      tail = tail[0..-2]
      hit = find_by(code: "#{base}.#{tail}")
      return hit if hit
    end
    find_by(code: base)
  end

  def tooltip_text
    [simple_description, hospice_context].compact_blank.join(" ")
  end

  private

  def upcase_code
    self.code = code.to_s.upcase.strip if code.present?
  end
end
