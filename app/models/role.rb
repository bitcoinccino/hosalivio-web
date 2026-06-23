class Role < ApplicationRecord
  # Global vocabulary — not tenant-scoped. Every agency uses the same role names.

  ROLE_NAMES = %w[
    rn lpn md don admissions dme pharmacy insurance billing
    chaplain social_worker aide family admin
  ].freeze

  has_many :user_roles, dependent: :destroy
  has_many :users, through: :user_roles

  validates :name,  presence: true, uniqueness: true, inclusion: { in: ROLE_NAMES }
  validates :label, presence: true
end
