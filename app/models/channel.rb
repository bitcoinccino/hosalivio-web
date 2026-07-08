# An agency-wide team-chat channel (e.g. #General, #Admission) — a non-patient
# conversation space, distinct from the patient-scoped chat (Note). Access is
# role-based: everyone on staff can read the MVP channels, but posting can be
# restricted to a channel's `post_roles`. Family never sees team channels.
class Channel < ApplicationRecord
  acts_as_tenant :agency

  belongs_to :agency
  has_many :channel_messages, -> { order(:created_at) }, dependent: :destroy

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: { scope: :agency_id }

  scope :ordered, -> { order(:position, :name) }

  # The two seeded MVP channels + their posting rules.
  #   #General   — any staff may post (post_roles: []).
  #   #Admission — core admission team posts; other staff read-only.
  DEFAULTS = [
    { slug: "general",   name: "General",   position: 0, post_roles: [],
      description: "Team announcements and general discussion." },
    { slug: "admission", name: "Admission", position: 1, post_roles: %w[admin rn md admissions],
      description: "Referrals, pre-admit evals, blockers, and scheduling." }
  ].freeze

  # Idempotently provision the default channels for an agency (lazy — called on
  # the team-chat index so every agency always has them).
  def self.ensure_defaults_for(agency)
    DEFAULTS.each do |attrs|
      find_or_create_by!(agency: agency, slug: attrs[:slug]) do |c|
        c.name        = attrs[:name]
        c.description = attrs[:description]
        c.post_roles  = attrs[:post_roles]
        c.position    = attrs[:position]
        c.system      = true
      end
    end
  end

  # All staff (never family) can read the MVP channels.
  def readable_by?(user)
    !user.family_access?
  end

  # Empty post_roles => any staff may post; otherwise the user needs a listed role.
  def postable_by?(user)
    return false unless readable_by?(user)
    post_roles.empty? || (user.role_names & post_roles).any?
  end

  # Managing channels (create / rename / delete) is admin-only.
  def manageable_by?(user)
    !user.family_access? && user.role_names.include?("admin")
  end

  def to_param = slug
end
