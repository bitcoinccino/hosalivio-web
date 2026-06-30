# Deterministic, LLM-free patient status summary — the graceful fallback when the
# answer brain is unavailable (provider outage / no credits). A clinician asking
# "summarize <patient>" still gets the real chart facts instead of an apology.
#
# Clinician-facing: leads with code status + diagnosis, flags unassigned core
# roles and open eval blockers, and counts visits/meds. Pure reads, nil-safe.
class PatientStatusSummary
  def self.call(patient:, role: "rn")
    new(patient, role).call
  end

  def initialize(patient, role)
    @p    = patient
    @role = role.to_s
  end

  def call
    ([ intro, "" ] + sections.compact).join("\n")
  rescue => e
    Rails.logger.warn("[PatientStatusSummary] #{e.class}: #{e.message}")
    "I can't reach the AI assistant right now — open #{@p.first_name}'s chart for the current status."
  end

  private

  def sections
    [ demographics, care_team, eval_status, visits, meds ]
  end

  def intro
    "Here's #{@p.full_name}'s status straight from the chart (the AI summary is briefly unavailable):"
  end

  def demographics
    bits = []
    bits << "#{@p.age_years} yrs"          if @p.respond_to?(:age_years) && @p.age_years
    bits << @p.code_status.to_s.upcase     if @p.code_status.present?
    line  = "• #{@p.full_name}"
    line += " · #{bits.join(' · ')}"       if bits.any?
    dx = @p.primary_diagnosis.to_s.strip
    line += "\n  Diagnosis: #{dx}"         if dx.present?
    line
  end

  def care_team
    rn  = @p.assigned_rn&.full_name
    vrn = @p.assigned_visit_rn&.full_name
    md  = @p.assigned_md&.full_name
    "• Care team: Admission RN #{rn || '⚠ unassigned'} · Visit RN #{vrn || '⚠ unassigned'} · MD #{md || '⚠ unassigned'}"
  end

  def eval_status
    ev = @p.pre_admit_evals.order(:created_at).last
    return "• Admission eval: not started" unless ev
    blockers = (ev.respond_to?(:certification_blockers) ? Array(ev.certification_blockers) : []).reject(&:blank?)
    line  = "• Admission eval: #{ev.status}"
    line += " — not certifiable yet. Open: #{blockers.to_sentence}" if blockers.any?
    line
  end

  def visits
    vs = @p.visits.to_a
    return "• Visits: none on record" if vs.empty?
    parts = []
    parts << "#{vs.count { |v| v.ended_at }} completed"                          if vs.any? { |v| v.ended_at }
    parts << "#{vs.count { |v| v.started_at && v.ended_at.nil? }} in progress"   if vs.any? { |v| v.started_at && v.ended_at.nil? }
    sched = vs.select { |v| v.started_at.nil? && v.ended_at.nil? }
    if sched.any?
      next_at = sched.filter_map(&:scheduled_at).min
      parts << (next_at ? "next scheduled #{next_at.to_date.strftime('%b %-d')}" : "#{sched.size} scheduled")
    end
    "• Visits: #{parts.join(' · ')}"
  end

  def meds
    n = @p.medication_orders.where(status: :active).count
    n.zero? ? "• Active meds: none on record" : "• Active meds: #{n} active order#{'s' if n != 1}"
  end
end
