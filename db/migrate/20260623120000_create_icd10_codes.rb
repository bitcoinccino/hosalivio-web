class CreateIcd10Codes < ActiveRecord::Migration[8.1]
  def change
    # Full searchable ICD-10-CM index (~72k codes) powering the diagnosis
    # autocomplete on the admissions form. Distinct from icd10_explanations,
    # which is the small, curated, family-facing plain-English layer.
    enable_extension "pg_trgm" unless extension_enabled?("pg_trgm")

    create_table :icd10_codes, id: :uuid do |t|
      t.string  :code,        null: false   # formatted with decimal, e.g. "E11.9"
      t.string  :description, null: false
      t.boolean :billable,    null: false, default: true
      t.timestamps
    end

    add_index :icd10_codes, :code, unique: true
    # Prefix search on code (E11%) and fuzzy/substring search on description.
    add_index :icd10_codes, :code, name: "index_icd10_codes_on_code_pattern",
              opclass: :varchar_pattern_ops
    add_index :icd10_codes, :description, using: :gin, opclass: :gin_trgm_ops,
              name: "index_icd10_codes_on_description_trgm"
  end
end
