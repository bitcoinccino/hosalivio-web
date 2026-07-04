# Builds the @-mention pool for chat composers: active, non-family staff in an
# agency (excluding the current user). Each entry: { handle, name, role }.
# Shared by the Mission Stage composer and the team-channel composer.
module MentionablePool
  extend ActiveSupport::Concern

  MENTION_ROLE_LABELS = {
    "rn" => "RN", "lpn" => "LPN", "md" => "MD", "don" => "DON",
    "social_worker" => "SW", "sw" => "SW", "chaplain" => "Chaplain",
    "aide" => "Aide", "admissions" => "Admissions", "insurance" => "Insurance",
    "billing" => "Billing", "admin" => "Admin", "pharmacy" => "Pharmacy", "dme" => "DME"
  }.freeze
  MENTION_ROLES = MENTION_ROLE_LABELS.keys.freeze

  private

  def build_mentionables(agency, viewer)
    return [] if agency.nil?

    User.unscoped
        .joins(user_roles: :role)
        .where(agency_id: agency.id, active: true, family_access: false)
        .where(roles: { name: MENTION_ROLES })
        .where.not(id: viewer.id)
        .distinct.order(:full_name).limit(40).to_a.filter_map do |u|
      first = u.full_name.to_s.split.first
      next if first.blank?
      role = (u.role_names & MENTION_ROLES).first
      { handle: first, name: u.full_name, role: MENTION_ROLE_LABELS[role] || role.to_s.titleize }
    end
  end
end
