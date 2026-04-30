# Records one round trip when an MD reviewing a finalized pre-admit
# eval asks the RN to revise something. The eval bounces back to
# :draft, the RN sees a banner with `comment`, and `resolved_at`
# stamps when the RN re-routes the eval. Audit purpose: every
# back-and-forth is an immutable row a CMS auditor can read
# alongside the certify event in `signatures`.
class EvalRevisionRequest < ApplicationRecord
  belongs_to :pre_admit_eval
  belongs_to :requester, class_name: "User"

  validates :comment, presence: true, length: { minimum: 5, maximum: 2000 }

  scope :open,         -> { where(resolved_at: nil) }
  scope :recent_first, -> { order(created_at: :desc) }

  def open? = resolved_at.nil?
  def resolved? = !open?
  def mark_resolved!
    update!(resolved_at: Time.current) if open?
  end
end
