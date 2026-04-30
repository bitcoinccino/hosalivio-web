# Anonymous reactions on public-chat AI replies. Drives prompt
# tuning + retrieval-quality evals: we look at clusters of
# `not_helpful` rows to spot where the brain is hallucinating
# or being cold, and `helpful` rows confirm the prompts that
# are landing.
class ChatFeedback < ApplicationRecord
  RATINGS = %w[helpful not_helpful].freeze
  AUDIENCES = %w[family partner].freeze

  validates :rating,    inclusion: { in: RATINGS }
  validates :audience,  inclusion: { in: AUDIENCES, allow_nil: true }
  validates :question,  presence: true, length: { maximum: 2_000 }
  validates :answer,    presence: true, length: { maximum: 4_000 }
  validates :comment,   length: { maximum: 1_000 }

  scope :recent_first, -> { order(created_at: :desc) }
  scope :helpful,      -> { where(rating: "helpful") }
  scope :not_helpful,  -> { where(rating: "not_helpful") }
end
