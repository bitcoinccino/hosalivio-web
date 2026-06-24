# Tracks one outbound transmission of a PreAdmitEval to an external EMR
# (e.g. the VITAS portal). The lifecycle column doubles as an idempotency
# guard: VitasEmrSyncJob find_or_create_by's a single row per (eval, target)
# and short-circuits once it reads "synchronized".
class EmrSyncLog < ApplicationRecord
  acts_as_tenant :agency

  belongs_to :pre_admit_eval
  belongs_to :agency

  STATUSES = %w[pending processing synchronized failed].freeze

  validates :status,        inclusion: { in: STATUSES }
  validates :target_system, presence: true

  scope :synchronized, -> { where(status: "synchronized") }
  scope :failed,       -> { where(status: "failed") }
end
