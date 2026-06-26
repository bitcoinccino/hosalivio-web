# Translates AgentEvents into human-readable "stories" for the Mission Stage.
# Structure: EventNarrator.stories_from(events, patient_lookup) -> [Story, …]
#
# Each Story has: event, extra_targets (for merged handoffs), and helpers to
# ask "what persona did this?" and "what sentence should I render?".

class EventNarrator
  PERSONA = {
    "admissions"         => { name: "HosAlivio",  title: "Admissions",   initials: "H", color: "#1D1C1A", icon: "ri-customer-service-2-line" },
    "hosalivio_brain"    => { name: "HosAlivio",  title: "",             initials: "H", color: "#1D1C1A", icon: "ri-sparkling-2-line" },
    "front_door_inbound" => { name: "Care Portal", title: "Family-facing", initials: "⌂", color: "#D97757", icon: "ri-feedback-line" },
    "rn"                 => { name: "Pascal",     title: "RN",           initials: "P", color: "#2F6F4E", icon: "ri-nurse-line" },
    "md"                 => { name: "Dr. Esther", title: "MD",           initials: "E", color: "#2B4A7A", icon: "ri-stethoscope-line" },
    "don"                => { name: "Diaphnie",   title: "DON",          initials: "D", color: "#8B5A2B", icon: "ri-award-line" },
    "social_worker"      => { name: "Nickla",     title: "Social Worker", initials: "N", color: "#7A4A8C", icon: "ri-team-line" },
    "chaplain"           => { name: "Geoginio",   title: "Chaplain",     initials: "G", color: "#8C6A2F", icon: "ri-hand-heart-line" },
    "pharmacy"           => { name: "Simone",     title: "Pharmacy",     initials: "S", color: "#5A2F7A", icon: "ri-capsule-line" },
    "dme"                => { name: "Marcus",     title: "DME",          initials: "M", color: "#3E5D5D", icon: "ri-tools-line" },
    "insurance"          => { name: "Kendra",     title: "Insurance",    initials: "K", color: "#3A3936", icon: "ri-shield-check-line" },
    "billing"            => { name: "Wolfwide",   title: "Billing",      initials: "W", color: "#6B665F", icon: "ri-bank-card-line" },
    "aide"               => { name: "Flore",      title: "Aide",         initials: "F", color: "#AD7340", icon: "ri-user-2-line" },
    "family"             => { name: "Family",     title: "Care Portal",  initials: "♥", color: "#D97757", icon: "ri-user-heart-line" },
    "system"             => { name: "HosAlivio",  title: "System",       initials: "•", color: "#6B665F", icon: "ri-flashlight-line" }
  }.freeze

  ROLE_LABEL = {
    "rn" => "RN", "md" => "MD", "don" => "DON", "aide" => "Aide",
    "social_worker" => "Social Work", "chaplain" => "Chaplain",
    "pharmacy" => "Pharmacy", "dme" => "DME", "insurance" => "Insurance",
    "billing" => "Billing", "admissions" => "Admissions"
  }.freeze

  def self.persona_for(agent_id)
    PERSONA[agent_id] || { name: agent_id.to_s.humanize, title: "", initials: agent_id.to_s[0].to_s.upcase, color: "#6B665F", icon: "ri-user-line" }
  end

  # Collapse adjacent handoffs for the same patient into one story.
  # `events` is expected in reverse-chronological order (newest first).
  def self.stories_from(events, patient_lookup:)
    stories = []
    i = 0
    while i < events.length
      ev = events[i]
      if handoff?(ev)
        # Walk forward (older events) collecting mergeable handoffs
        targets = [ ev.change_set["target_role"] ]
        j = i + 1
        while j < events.length && mergeable_handoff?(ev, events[j])
          targets << events[j].change_set["target_role"]
          j += 1
        end
        stories << Story.new(event: ev, extra_targets: targets, patient_lookup: patient_lookup)
        i = j
      else
        stories << Story.new(event: ev, extra_targets: [], patient_lookup: patient_lookup)
        i += 1
      end
    end
    stories
  end

  def self.handoff?(ev)
    ev.action == "handoff" && ev.change_set.is_a?(Hash) && ev.change_set["target_role"].present?
  end

  # Two handoffs merge if: same agent, same patient, within 60 s.
  def self.mergeable_handoff?(a, b)
    return false unless handoff?(b)
    return false unless a.agent_id == b.agent_id
    return false unless a.subject_type == b.subject_type && a.subject_id == b.subject_id
    (a.happened_at - b.happened_at).abs <= 60
  end

  # ────────────────────────────────────────────────────────────────────
  class Story
    attr_reader :event, :extra_targets

    def initialize(event:, extra_targets:, patient_lookup:)
      @event          = event
      @extra_targets  = extra_targets.compact.uniq
      @patient_lookup = patient_lookup
    end

    def persona = EventNarrator.persona_for(event.agent_id)

    def category
      return "feedback" if event.agent_id == "feedback"

      case event.action
      when "thumbs_up", "thumbs_down", "thumbs_clear", "feedback_thumbs_up", "feedback_thumbs_down", "feedback"
        "feedback"
      when "handoff"
        "handoffs"
      when "answer_clinician_question", "polish_narrative"
        "clinical"
      else
        case event.subject_type
        when "Note", "Visit", "MedicationOrder", "MedicationLog", "PreAdmitEval"
          "clinical"
        when "PharmacyDelivery", "DmeOrder", "Inquiry", "Patient"
          "ops"
        else
          "all"
        end
      end
    end

    # Returns { before:, after:, icon: }.
    # The caller renders: "<persona> <before> <patient_link> <after>"
    # Example: "HosAlivio (Admissions) | assigned | Maria Alvarez | to the RN + MD team"
    def narrate
      case [ event.agent_id, event.action, event.subject_type ]
      in [ "admissions", "handoff", "Patient" ]
        targets_text = @extra_targets.map { |r| EventNarrator::ROLE_LABEL[r] || r.to_s.humanize }.join(" + ")
        { before: "assigned", after: "to the #{targets_text} team", icon: "ri-send-plane-2-line" }
      in [ _, "handoff", "Patient" ]
        target = event.change_set.is_a?(Hash) ? event.change_set["target_role"] : nil
        team = EventNarrator::ROLE_LABEL[target] || target.to_s.humanize.presence || "care team"
        { before: "asked the #{team} team to follow up with", after: "", icon: "ri-send-plane-2-line" }
      in [ "admissions", "create", "Note" ]
        crisis = event.subject&.urgency == "crisis" ? " (crisis triage)" : ""
        { before: "posted a triage update for", after: crisis, icon: "ri-chat-3-line" }
      in [ "front_door_inbound", "create", "Note" ]
        urgency = event.subject&.urgency
        after   = urgency == "crisis" ? "'s family — marked CRISIS" : "'s family"
        { before: "logged a new concern from", after: after, icon: "ri-feedback-line" }
      in [ _, "answer_clinician_question", "Patient" ]
        { before: "answered a care-team question about", after: "", icon: "ri-question-answer-line" }
      in [ _, "polish_narrative", "Visit" ]
        { before: "cleaned up the visit narrative for", after: "", icon: "ri-quill-pen-line" }
      in [ _, "create", "Note" ]
        { before: "added a care note for", after: "", icon: "ri-sticky-note-line" }
      in [ "feedback", "thumbs_up", "Note" ]
        { before: "marked a note helpful for", after: "", icon: "ri-thumb-up-line" }
      in [ "feedback", "thumbs_down", "Note" ]
        { before: "flagged a note for review on", after: "'s chart", icon: "ri-thumb-down-line" }
      in [ "feedback", "thumbs_clear", "Note" ]
        { before: "cleared feedback on a note for", after: "", icon: "ri-eraser-line" }
      in [ _, "feedback_thumbs_up", "Note" ]
        { before: "marked a note helpful for", after: "", icon: "ri-thumb-up-line" }
      in [ _, "feedback_thumbs_down", "Note" ]
        { before: "flagged a note for review on", after: "'s chart", icon: "ri-thumb-down-line" }
      in [ _, "create", "MedicationOrder" ]
        drug = event.subject&.drug_name
        { before: "authorized a new medication order#{drug ? " (#{drug})" : ''} for", after: "", icon: "ri-capsule-line" }
      in [ _, "update", "MedicationOrder" ]
        { before: "updated a medication order for", after: "", icon: "ri-capsule-line" }
      in [ _, "create", "MedicationLog" ]
        { before: "administered a scheduled dose to", after: "", icon: "ri-syringe-line" }
      in [ _, "create", "Visit" ]
        kind = event.subject&.visit_type&.tr("_", " ")
        { before: "started a#{kind ? " #{kind}" : ''} bedside visit with", after: "", icon: "ri-nurse-line" }
      in [ _, "create", "PharmacyDelivery" ]
        { before: "requested a pharmacy delivery for", after: "", icon: "ri-truck-line" }
      in [ _, "update", "PharmacyDelivery" ]
        s = event.subject&.status
        { before: "updated a pharmacy delivery for", after: s ? "— #{s.to_s.tr('_', ' ')}" : "", icon: "ri-truck-line" }
      in [ _, "create", "DmeOrder" ]
        eq = event.subject&.equipment_type&.tr("_", " ")
        { before: "ordered#{eq ? " a #{eq}" : ' equipment'} for", after: "", icon: "ri-tools-line" }
      in [ _, "create", "Patient" ]
        { before: "admitted", after: "as a new referral", icon: "ri-user-add-line" }
      in [ _, "update", "Patient" ]
        { before: "updated", after: "'s chart", icon: "ri-edit-2-line" }
      in [ _, "update", "Note" ]
        { before: "acknowledged a note on", after: "'s chart", icon: "ri-check-line" }
      in [ "admissions", "inquiry_received", "Inquiry" ]
        cs         = event.change_set || {}
        first_name = cs["first_name"].presence || "Someone"
        zip        = cs["zip_prefix"].presence || "unknown"
        qualifier  = cs["is_general"] ? "general inquiry" : "targeted inquiry"
        source     = cs["source_prompt"].to_s.tr("_", " ")
        source_hint = source.present? ? " via #{source}" : ""
        {
          before: "received a #{qualifier} from #{first_name} (ZIP #{zip}xx)#{source_hint}",
          after:  "",
          icon:   "ri-mail-add-line"
        }
      in [ "admissions", "inquiry_converted", "Inquiry" ]
        cs         = event.change_set || {}
        first_name = cs["first_name"].presence || "the family"
        mrn        = cs["patient_mrn"].presence
        who        = cs["converted_by"].presence
        suffix     = mrn ? "into an active referral (#{mrn})" : "into an active referral"
        suffix    += " — converted by #{who}" if who
        {
          before: "converted #{first_name}'s inquiry",
          after:  suffix,
          icon:   "ri-user-add-line"
        }
      else
        action = event.action.to_s.tr("_", " ")
        subject = event.subject_type.to_s.underscore.humanize.downcase.presence || "record"
        { before: "#{action} for", after: "(#{subject})", icon: "ri-settings-3-line" }
      end
    end

    # The patient this event is ABOUT (nullable).
    def patient
      pid =
        if event.subject_type == "Patient"
          event.subject_id
        elsif event.subject.respond_to?(:patient_id)
          event.subject.patient_id
        end
      pid ? @patient_lookup[pid] : nil
    end

    def urgency_crisis?
      event.subject.respond_to?(:urgency) && event.subject.urgency == "crisis"
    end
  end
end
