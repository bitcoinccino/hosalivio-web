class UserRole < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail

  belongs_to :user
  belongs_to :role
  belongs_to :agency

  validates :user_id, uniqueness: { scope: [:role_id, :agency_id] }
end
