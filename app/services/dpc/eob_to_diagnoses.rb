module Dpc
  # Turns a Data-at-the-Point-of-Care bulk export — NDJSON of FHIR
  # ExplanationOfBenefit resources — into a deduped Medicare diagnosis history
  # the admission eval can surface as suggested comorbidities / decline evidence
  # (advisory; the RN confirms, nothing auto-commits).
  #
  # Pure parsing: no network, no DB writes. Tested directly with sample FHIR.
  class EobToDiagnoses
    # FHIR ICD-10 code systems seen in CMS/BlueButton EOBs (CM + the legacy slug).
    ICD10_SYSTEMS = [
      "http://hl7.org/fhir/sid/icd-10-cm",
      "http://hl7.org/fhir/sid/icd-10"
    ].freeze

    # One diagnosis row in the rolled-up history.
    Diagnosis = Struct.new(:icd10, :description, :last_seen, :count, keyword_init: true)

    def self.call(ndjson)
      new(ndjson).call
    end

    def initialize(ndjson)
      @ndjson = ndjson.to_s
    end

    # Newest-first by last service date, then most-frequent, then code.
    def call
      rolled = {}
      each_eob do |eob|
        date = service_date(eob)
        Array(eob["diagnosis"]).each do |dx|
          icd, display = icd10_from(dx)
          next if icd.nil?
          row = (rolled[icd] ||= Diagnosis.new(icd10: icd, description: nil, last_seen: nil, count: 0))
          row.count += 1
          row.description ||= display.presence || local_description(icd)
          row.last_seen = [ row.last_seen, date ].compact.max
        end
      end
      rolled.values.sort_by { |r| [ r.last_seen ? -r.last_seen.to_time.to_i : 0, -r.count, r.icd10 ] }
    end

    private

    # Yields each parsed ExplanationOfBenefit hash; skips blank/garbled lines so
    # one bad row in a large export doesn't sink the whole import.
    def each_eob
      @ndjson.each_line do |line|
        s = line.strip
        next if s.empty?
        obj = begin
          JSON.parse(s)
        rescue JSON::ParserError
          nil
        end
        next unless obj.is_a?(Hash) && obj["resourceType"] == "ExplanationOfBenefit"
        yield obj
      end
    end

    # [code, display] from a FHIR diagnosis entry, or nil when not ICD-10.
    def icd10_from(dx)
      codings = Array(dx.dig("diagnosisCodeableConcept", "coding"))
      coding  = codings.find { |c| ICD10_SYSTEMS.include?(c["system"].to_s) }
      return nil unless coding
      code = coding["code"].to_s.strip.upcase
      return nil if code.empty?
      [ code, coding["display"].to_s.strip ]
    end

    # Canonical description from the local ICD-10-CM index, when the EOB coding
    # didn't carry a display string.
    def local_description(code)
      Icd10Code.where("REPLACE(UPPER(code), '.', '') = ?", code.delete(".")).first&.description
    end

    def service_date(eob)
      raw = eob.dig("billablePeriod", "end") ||
            eob.dig("billablePeriod", "start") ||
            Array(eob["item"]).filter_map { |i| i["servicedDate"] }.max
      Date.parse(raw.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
