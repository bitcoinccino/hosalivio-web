class Notification < ApplicationRecord
  acts_as_tenant :agency

  belongs_to :agency
  belongs_to :user
  belongs_to :linked, polymorphic: true, optional: true

  validates :kind, :title, presence: true

  scope :unread,     -> { where(read_at: nil) }
  scope :newest_first, -> { order(created_at: :desc) }

  def read?  = read_at.present?
  def mark_read!(at = Time.current) = update!(read_at: at)
end
