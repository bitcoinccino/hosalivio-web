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

  private

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
