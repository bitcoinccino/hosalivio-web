# Wakes the target agent when an AgentEvent("handoff") lands.
# Reads the event, builds runtime context for the target role, delegates to
# AgentBrain, hands the decision to AgentTriager for execution.
#
# Runs in the solid_queue default queue. Depth-capped so chains can't loop.

class AgentResponseJob < ApplicationJob
  queue_as :default

  # Don't wake target roles we know have no SOUL yet. Avoids pointless LLM
  # calls and avoids creating "no_action" audit notes for every handoff while
  # the roster is still being written.
  CONFIGURED_ROLES = %w[admissions rn lpn md pharmacy social_worker chaplain dme aide insurance billing].freeze

  def perform(agent_event_id)
    event = AgentEvent.unscoped.find_by(id: agent_event_id)
    return unless event && event.action == "handoff"

    target_role = event.change_set.is_a?(Hash) ? event.change_set["target_role"].to_s : ""
    return if target_role.blank?
    return unless CONFIGURED_ROLES.include?(target_role)

    depth = (event.change_set["depth"] || 1).to_i
    return if depth > AgentBrain::MAX_DEPTH

    agency = event.agency
    return if agency.nil?

    ActsAsTenant.with_tenant(agency) do
      context  = build_context(event)
      decision = AgentBrain.call(role: target_role, agency: agency, event: event, context: context, depth: depth)

      # Phase-3 guard: scan chart-bound output for hedges, forbidden topics,
      # ungrounded numbers, and placeholders. If flagged, the guard swaps the
      # decision for a no_action carrying the failure reasons in its reasoning.
      guard_result = ClinicalDocumentationGuard.check(role: target_role, decision: decision, context: context)

      AgentTriager.new(role: target_role, agency: agency, event: event, depth: depth).apply(guard_result.decision)
    end
  end

  private

  # Compact, decryption-aware snapshot of the patient and their recent history.
  def build_context(event)
    patient = patient_from(event)
    return { intent: event.change_set["intent"], urgency: event.change_set["urgency"], patient: {} } if patient.nil?

    {
      intent:   event.change_set["intent"],
      urgency:  event.change_set["urgency"],
      patient: {
        id:                patient.id,
        mrn:               patient.mrn,
        full_name:         patient.full_name,
        age:               patient.age_years,
        primary_diagnosis: patient.primary_diagnosis,
        code_status:       patient.code_status,
        status:            patient.status,
        assigned_rn:       patient.assigned_rn&.full_name,
        assigned_md:       patient.assigned_md&.full_name
      },
      active_meds:  patient.medication_orders.where(status: :active).limit(5).map { |m|
                      "#{m.drug_name} #{m.dose} #{m.route.upcase} #{m.frequency}#{' PRN' if m.prn}"
                    },
      recent_notes: patient.notes.order(created_at: :desc).limit(5).map { |n|
                      { role: n.author_role, body: n.body.to_s[0, 240] }
                    },
      # Huddle awareness (Rule 3): which other disciplines are already visiting
      # this patient today? The agent reads this and defers if the day is full.
      visits_today_by_discipline: Visit.disciplines_scheduled_for(
        patient_id: patient.id, on_date: Date.current
      )
    }
  end

  def patient_from(event)
    return event.subject if event.subject.is_a?(Patient)
    return event.subject.patient if event.subject.respond_to?(:patient)
    nil
  end
end
