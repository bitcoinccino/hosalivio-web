class AgentEvent < ApplicationRecord
  # Audit trail for agent-driven writes.
  # Humans are tracked via PaperTrail's `versions` table (whodunnit = user id).
  # Agents are tracked here, keyed by agent role + OpenClaw session id.

  acts_as_tenant :agency

  belongs_to :agency
  belongs_to :subject, polymorphic: true, optional: true
  belongs_to :acknowledged_by_user, class_name: "User", optional: true

  validates :agent_id, :action, :happened_at, presence: true

  scope :pending,      -> { where(acknowledged_at: nil) }
  scope :acknowledged, -> { where.not(acknowledged_at: nil) }

  def acknowledged?
    acknowledged_at.present?
  end

  def acknowledge!(user)
    return false if acknowledged?
    update!(acknowledged_at: Time.current, acknowledged_by_user: user)
  end

  # Broadcast to the patient's live channel + the agency's mission stage
  # when the subject is a clinical record.
  after_create_commit :broadcast_live_update

  # Wake the target agent when a handoff lands. The job is tenant-scoped
  # and depth-capped inside AgentResponseJob / AgentBrain.
  after_create_commit :wake_target_agent, if: -> { action.to_s == "handoff" }

  # Live-update My Day for clinicians whose role queue this handoff
  # targets (e.g. action="handoff" + target_role="rn" refreshes every
  # RN's Handoffs Waiting card without a page reload).
  after_create_commit :broadcast_dashboard_handoff, if: -> { action.to_s == "handoff" }

  def broadcast_dashboard_handoff
    role = change_set.is_a?(Hash) ? change_set["target_role"].to_s : nil
    return if role.blank?
    User.unscoped
        .where(agency_id: agency_id, active: true, family_access: false)
        .joins(user_roles: :role)
        .where(roles: { name: role })
        .find_each do |target|
      data = DashboardData.for(target)
      Turbo::StreamsChannel.broadcast_replace_to(
        "dashboard:user:#{target.id}",
        target:  "dashboard-handoffs-#{target.id}",
        partial: "dashboards/handoffs_card",
        locals:  { pending_handoffs: data.pending_handoffs, viewer_user_id: target.id }
      )
    end
  rescue => e
    Rails.logger.warn("[AgentEvent#broadcast_dashboard_handoff] #{e.class}: #{e.message}")
  end

  def wake_target_agent
    AgentResponseJob.perform_later(id)
  end

  def broadcast_live_update
    patient_id = subject.try(:patient_id) || (subject.is_a?(Patient) ? subject.id : nil)

    if patient_id
      ActionCable.server.broadcast(
        "patient:#{patient_id}",
        { event: action, subject_type: subject_type, subject_id: subject_id,
          agent_id: agent_id, happened_at: happened_at, change_set: change_set }
      )
    end

    ActionCable.server.broadcast(
      "mission_stage:#{agency_id}",
      mission_stage_payload(patient_id)
    )
  end

  def mission_stage_payload(patient_id)
    patient = Patient.unscoped.where(id: patient_id).first if patient_id
    drug    = subject.respond_to?(:drug_name)      ? subject.drug_name      : nil
    visit   = subject.respond_to?(:visit_type)     ? subject.visit_type     : nil
    equip   = subject.respond_to?(:equipment_type) ? subject.equipment_type : nil

    # Inquiry subjects carry a few landing-page fields the dashboard narrator uses.
    inquiry_bits =
      if subject.is_a?(Inquiry)
        cs = change_set.is_a?(Hash) ? change_set : {}
        {
          first_name:    subject.first_name,
          zip_prefix:    subject.zip_prefix,
          is_general:    subject.is_general,
          source_prompt: subject.source_prompt,
          agency_name:   subject.agency&.name,
          # Populated only on `inquiry_converted` events; nil otherwise.
          patient_mrn:   cs["patient_mrn"].presence  || patient&.mrn,
          converted_by:  cs["converted_by"]
        }
      else
        {}
      end

    {
      event:         action,
      subject_type:  subject_type,
      subject_id:    subject_id,
      agent_id:      agent_id,
      patient_id:    patient_id,
      happened_at:   happened_at&.iso8601,
      urgency:       subject.respond_to?(:urgency) ? subject.urgency : nil,
      handoff_role:  change_set.is_a?(Hash) ? change_set["target_role"]  : nil,
      intent:        change_set.is_a?(Hash) ? change_set["intent"]       : nil,
      patient_mrn:   patient&.mrn,
      patient_name:  patient&.full_name,
      drug_name:     drug,
      visit_type:    visit,
      equipment_type: equip
    }.merge(inquiry_bits).compact
  end
end
