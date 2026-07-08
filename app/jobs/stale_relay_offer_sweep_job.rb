# Safety net for held family-relay drafts. When HosAlivio drafts a family-facing
# commitment, it holds it as a clinician-only "relay offer" and nudges the
# assigned RN to Send/Cancel (see ClinicianDispatcher.post_family_relay_offer +
# the relay_offer_pending notification). If that RN never acts, the family's
# promised update silently stalls — so this sweep escalates a still-pending
# offer to the DON (Director of Nursing) after STALE_AFTER.
#
# Idempotent: escalates each offer to the DON at most once (AgentEvent marker).
# Scheduled in config/recurring.yml. Run on demand:
#   bin/rails runner 'StaleRelayOfferSweepJob.perform_now'
class StaleRelayOfferSweepJob < ApplicationJob
  queue_as :default

  # How long an offer may sit unsent before the DON is looped in.
  STALE_AFTER = 45.minutes
  # Ignore offers older than this (already missed / handled out of band).
  LOOKBACK = 24.hours

  def perform
    escalated = 0
    ActsAsTenant.without_tenant do
      Agency.where(active: true).find_each do |agency|
        ActsAsTenant.with_tenant(agency) do
          # The RN-nudge notification (one per offer) is our bounded worklist;
          # its linked record is the offer note.
          Notification.where(kind: "relay_offer_pending", linked_type: "Note")
                      .where(created_at: LOOKBACK.ago..STALE_AFTER.ago)
                      .includes(:linked)
                      .find_each do |pending|
            offer = pending.linked
            next unless offer.is_a?(Note)
            # Still unsent? pending_relay_offer returns the offer only while it's
            # the latest AI note (a Send or Cancel posts a newer note).
            next unless ClinicianDispatcher.pending_relay_offer(offer.patient)&.id == offer.id
            escalated += 1 if escalate_to_manager(agency, offer)
          end
        end
      end
    end
    Rails.logger.info("[StaleRelayOfferSweepJob] escalated=#{escalated}")
  end

  private

  def escalate_to_manager(agency, offer)
    return false if AgentEvent.where(agency: agency, action: "relay_offer_escalated", subject: offer).exists?

    # DON was retired; the agency admin is now the escalation owner for an
    # unsent family draft.
    manager = User.joins(user_roles: :role)
                  .where(agency: agency, active: true, family_access: false, roles: { name: "admin" })
                  .first
    return false unless manager

    waited = STALE_AFTER.to_i / 60
    # Address the recipient by their human role label.
    label  = HosalivioTriager::ROLE_LABELS.fetch("admin", "administrator")
    AgentEvent.create!(
      agency:           agency,
      agent_id:         "system",
      agent_session_id: "relay-escalation-#{SecureRandom.hex(3)}",
      action:           "relay_offer_escalated",
      subject:          offer,
      change_set:       { patient_id: offer.patient_id, waited_minutes: waited },
      happened_at:      Time.current
    )
    Notification.create!(
      agency: agency,
      user:   manager,
      kind:   "relay_offer_escalated",
      title:  "Unsent family draft needs your review — #{offer.patient.first_name}",
      body:   "A drafted family update has waited over #{waited} minutes without the assigned nurse sending it. As #{label}, please review or reassign.",
      linked: offer
    )
    true
  rescue => e
    Rails.logger.warn("[StaleRelayOfferSweepJob] escalation failed for offer=#{offer.id}: #{e.class} #{e.message}")
    false
  end
end
