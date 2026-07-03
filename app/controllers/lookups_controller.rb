class LookupsController < ApplicationController
  before_action :authenticate_user!

  # GET /lookups/icd10?q=diabetes  -> [{ code:, description: }, ...]
  # Diagnosis autocomplete for the admissions form.
  def icd10
    results = Icd10Code.search(params[:q].to_s).map(&:as_suggestion)
    render json: results
  end

  # GET /lookups/zip/33139 -> { zip:, city:, state:, county:, branch: {...} }
  # Address autofill + suggested clinical branch (tenant-scoped) for a ZIP.
  def zip
    zip = ZipCode.lookup(params[:zip])
    return render(json: { found: false }, status: :not_found) unless zip

    payload = zip.as_json_payload.merge(found: true, branch: suggested_branch(zip.zip))
    render json: payload
  end

  # GET /lookups/physician?name=Jane+Smith&state=FL&zip=33139
  # Resolves an attending physician to a single unambiguous NPI via NPPES.
  # Dormant unless NPI_LIVE_LOOKUP is set (Coding::Npi returns nil otherwise),
  # so this simply reports { found: false } when the connector is off.
  def physician
    first, last = split_name(params[:name])
    return render(json: { found: false }) if last.blank?

    result = Coding::Npi.lookup(
      first_name:  first,
      last_name:   last,
      state:       params[:state].to_s.strip.presence,
      postal_code: params[:zip].to_s.gsub(/\D/, "").first(5).presence
    )
    return render(json: { found: false }) unless result

    render json: { found: true, npi: result.npi, name: result.name,
                   credential: result.credential, taxonomy: result.taxonomy }
  end

  private

  # "Dr. Jane A. Smith, MD" -> ["Jane A.", "Smith"]. Strips a courtesy prefix and
  # a trailing credential suffix; the last remaining token is the surname.
  def split_name(raw)
    cleaned = raw.to_s.strip
    cleaned = cleaned.sub(/\A(dr\.?|doctor|mr\.?|mrs\.?|ms\.?)\s+/i, "")
    cleaned = cleaned.sub(/,.*\z/, "")
    parts = cleaned.split(/\s+/).reject(&:blank?)
    return [ nil, nil ]         if parts.empty?
    return [ nil, parts.first ] if parts.size == 1
    [ parts[0..-2].join(" "), parts.last ]
  end

  # The branch that should serve this ZIP, within the signed-in user's agency.
  def suggested_branch(zip)
    return nil unless current_user&.agency

    branch = ActsAsTenant.with_tenant(current_user.agency) do
      Branch.route_for_zip(current_user.agency, zip)
    end
    return nil unless branch

    { id: branch.id, name: branch.name, location: branch.location_label,
      covers: branch.covers_zip?(zip) }
  end
end
