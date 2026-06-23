require "zlib"

# Importers for the bundled reference datasets that power the admissions form.
# Both read vendored, gzipped files under db/data so the import is reproducible
# offline. Idempotent: re-running upserts on the unique key.
namespace :reference do
  desc "Load the full ICD-10-CM code index (db/data/icd10cm_codes.tsv.gz)"
  task icd10: :environment do
    path = Rails.root.join("db/data/icd10cm_codes.tsv.gz")
    abort "Missing #{path}" unless File.exist?(path)

    now = Time.current
    batch = []
    total = 0
    flush = lambda do
      next if batch.empty?
      Icd10Code.upsert_all(batch, unique_by: :code)
      total += batch.size
      batch.clear
      print "\r  imported #{total} ICD-10 codes"
    end

    Zlib::GzipReader.open(path) do |gz|
      gz.each_line do |line|
        code, description = line.chomp.split("\t", 2)
        next if code.blank? || description.blank?
        batch << { code: code.upcase, description: description,
                   billable: true, created_at: now, updated_at: now }
        flush.call if batch.size >= 2_000
      end
    end
    flush.call
    puts "\n  done: #{Icd10Code.count} ICD-10 codes in table"
  end

  desc "Load the US ZIP -> city/state/county reference (db/data/us_zip_codes.tsv.gz)"
  task zips: :environment do
    path = Rails.root.join("db/data/us_zip_codes.tsv.gz")
    abort "Missing #{path}" unless File.exist?(path)

    now = Time.current
    batch = []
    total = 0
    flush = lambda do
      next if batch.empty?
      ZipCode.upsert_all(batch, unique_by: :zip)
      total += batch.size
      batch.clear
      print "\r  imported #{total} ZIP codes"
    end

    Zlib::GzipReader.open(path) do |gz|
      gz.each_line do |line|
        zip, city, state, county = line.chomp.split("\t")
        next unless zip =~ /\A\d{5}\z/
        batch << { zip: zip, city: city, state: state,
                   county: county, created_at: now, updated_at: now }
        flush.call if batch.size >= 2_000
      end
    end
    flush.call
    puts "\n  done: #{ZipCode.count} ZIP codes in table"
  end

  desc "Load all bundled reference datasets"
  task all: %i[icd10 zips]
end
