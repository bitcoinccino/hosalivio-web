class Icd10Code < ApplicationRecord
  # Full searchable ICD-10-CM index that backs the diagnosis autocomplete.
  # For the family-facing plain-English layer see Icd10Explanation.

  validates :code, presence: true, uniqueness: { case_sensitive: false }
  validates :description, presence: true

  before_validation { self.code = code.to_s.upcase.strip if code.present? }

  # Autocomplete search. A query that looks like a code (starts with a letter)
  # is matched as a code prefix first; everything else is a substring match on
  # the description. Code matches always rank above description matches.
  def self.search(query, limit: 12)
    q = query.to_s.strip
    return none if q.length < 2

    code_like = "#{q.upcase.delete('.')}%"
    desc_like = "%#{q}%"

    where("REPLACE(code, '.', '') LIKE :code OR description ILIKE :desc",
          code: code_like, desc: desc_like)
      .order(Arel.sql("CASE WHEN REPLACE(code, '.', '') LIKE #{connection.quote(code_like)} THEN 0 ELSE 1 END, length(code), code"))
      .limit(limit)
  end

  def as_suggestion
    { code: code, description: description }
  end
end
