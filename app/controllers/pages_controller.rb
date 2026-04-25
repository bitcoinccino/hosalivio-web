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
      @match = HosalivioMatchmaker.call(query: query, filters: filters)
      @all_specialties = Agency::SPECIALTY_CATALOG
      @all_insurance   = Agency::INSURANCE_CATALOG
      @all_languages   = Agency::LANGUAGE_CATALOG
      @active_query    = query
    end
  end

  # 'Coming soon' destination for the Upgrade to VHAS link in the user
  # menu. Authenticated + admin-only is enforced at the link level (the
  # menu only renders the link for admins); this just serves the page.
  def upgrade
    head(:forbidden) and return unless user_signed_in? && current_user.role_names.include?("admin")
  end

  # Left intact from earlier FAQ tree (still used by the educational prompts
  # in the side panel — we keep them as a secondary layer under the directory).
  HOSPICE_FAQS = [].freeze
end
