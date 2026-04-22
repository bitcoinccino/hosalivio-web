class PagesController < ApplicationController
  # Public landing. Agency-agnostic, cross-tenant directory.
  # Privacy wall: nothing typed here persists to a clinical record.

  def welcome
    @starters = LandingPrompts.starters
    @prompts_js = LandingPrompts.as_json_payload

    # Cross-tenant directory query. `ActsAsTenant.without_tenant` bypasses
    # the per-agency scope, which is correct for the public partner list.
    ActsAsTenant.without_tenant do
      query = params[:q].to_s.strip
      filters = {
        zip:       params[:zip],
        specialty: Array(params[:specialty]).compact_blank,
        insurance: Array(params[:insurance]).compact_blank,
        language:  Array(params[:language]).compact_blank
      }
      @match = LuciaMatchmaker.call(query: query, filters: filters)
      @all_specialties = Agency::SPECIALTY_CATALOG
      @all_insurance   = Agency::INSURANCE_CATALOG
      @all_languages   = Agency::LANGUAGE_CATALOG
      @active_query    = query
    end
  end

  # Left intact from earlier FAQ tree (still used by the educational prompts
  # in the side panel — we keep them as a secondary layer under the directory).
  HOSPICE_FAQS = [].freeze
end
