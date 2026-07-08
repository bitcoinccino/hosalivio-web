# Active tripwire for the Medicare NOE filing deadline — the single highest-
# stakes regulatory clock in the app (a missed 5-day window means every day of
# care from admission to filing is non-reimbursable). Until now the deadline was
# only surfaced passively on the Insurance dashboard; this sweep pushes it.
#
# For every certified-but-unfiled eval it computes a risk tier and alerts the
# right people via Notification (which fans out to the in-app bell + the
# recipient's outbound channel):
#   • within 2 days  → nudge the Insurance coordinator(s)
#   • overdue        → escalate to the DON + admin
#
# Idempotent the same way the other sweeps are: one Notification per
# eval + tier + user (DB-checked), so repeated cron runs never spam.
class NoeDeadlineSweepJob < ApplicationJob
  queue_as :default

  KIND_IMMINENT        = "noe_deadline_imminent"
  KIND_OVERDUE         = "noe_deadline_overdue"
  IMMINENT_WITHIN_DAYS = 2

  # role → tier routing
  IMMINENT_ROLES = %w[insurance].freeze
  OVERDUE_ROLES  = %w[admin].freeze

  def perform
    sent = 0
    ActsAsTenant.without_tenant do
      Agency.where(active: true).find_each do |agency|
        ActsAsTenant.with_tenant(agency) do
          PreAdmitEval.where(status: :certified).includes(:patient).find_each do |eval_rec|
            sent += sweep(agency, eval_rec)
          end
        end
      end
    end
    Rails.logger.info("[NoeDeadlineSweepJob] alerts_sent=#{sent}")
  end

  private

  def sweep(agency, eval_rec)
    return 0 if eval_rec.noe_deadline_at.blank?

    if eval_rec.noe_overdue?
      alert(agency, eval_rec, KIND_OVERDUE, OVERDUE_ROLES)
    elsif eval_rec.days_until_noe_deadline.to_i.between?(0, IMMINENT_WITHIN_DAYS)
      alert(agency, eval_rec, KIND_IMMINENT, IMMINENT_ROLES)
    else
      0
    end
  end

  def alert(agency, eval_rec, kind, role_names)
    recipients(agency, role_names).sum do |user|
      next 0 if already_alerted?(eval_rec, kind, user)
      Notification.create!(
        agency:       agency,
        user:         user,
        kind:         kind,
        title:        title_for(kind, eval_rec),
        body:         body_for(kind, eval_rec),
        linked:       eval_rec,
        delivered_at: Time.current
      )
      1
    end
  end

  # Explicit agency_id scope so global/system-admin users (nil agency) are excluded.
  def recipients(agency, role_names)
    User.where(agency_id: agency.id, active: true)
        .joins(:roles).where(roles: { name: role_names }).distinct
  end

  # Imminent (48h) is once-and-done to avoid clogging the insurance inbox.
  # Overdue re-nudges DAILY until the NOE is filed — a compounding billing
  # clawback is too dangerous to alert on only once (a single buried SMS during
  # an emergency shouldn't mean permanent silence). Scoping the existence check
  # to today expires the idempotency shield at midnight, so the first sweep each
  # calendar day re-escalates.
  def already_alerted?(eval_rec, kind, user)
    scope = Notification.where(kind: kind, linked_type: "PreAdmitEval", linked_id: eval_rec.id, user_id: user.id)
    scope = scope.where("created_at >= ?", Date.current.beginning_of_day) if kind == KIND_OVERDUE
    scope.exists?
  end

  def title_for(kind, eval_rec)
    who = eval_rec.patient&.full_name || "a patient"
    kind == KIND_OVERDUE ? "NOE OVERDUE — file immediately: #{who}" : "NOE due within 48h: #{who}"
  end

  def body_for(kind, eval_rec)
    who  = eval_rec.patient&.full_name || "this patient"
    days = eval_rec.days_until_noe_deadline.to_i
    if kind == KIND_OVERDUE
      "The Medicare NOE deadline passed #{-days} day(s) ago for #{who}. Every day unfiled is non-reimbursable — file the Notice of Election now."
    else
      "The Medicare NOE deadline for #{who} is in #{days} day(s). File the Notice of Election to protect the billing window."
    end
  end
end
