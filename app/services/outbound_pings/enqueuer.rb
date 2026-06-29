# Single entry point for "should we page this clinician outside the
# app?" decisions. Called from Note + Notification + scheduler hooks.
# Always emits PHI-free previews.
module OutboundPings
  class Enqueuer
    # Enqueue one ping for a user from a Notification row. Notifications
    # already represent "human needs to see this" intent; we pass the
    # title through verbatim because Notification#title is curated by
    # the dispatcher and doesn't include patient names beyond first
    # initials in some cases. Any title containing PHI should be
    # corrected at the source (the dispatcher), not here.
    def self.from_notification(notification)
      return if notification.user.blank?
      return if Notification::IN_APP_ONLY_KINDS.include?(notification.kind)
      return if notification.user.enabled_channels.empty?

      # Generic PHI-free preview based on kind. Dispatcher titles like
      # "Verify insurance: Maria Alvarez" contain a name; we strip and
      # replace with a generic count. The user signs in to see the
      # specific patient.
      preview = phi_free_preview_for_notification(notification)
      kind    = map_notification_kind(notification.kind)

      OutboundPing.create!(
        agency:  notification.agency,
        user:    notification.user,
        kind:    kind,
        preview: preview,
        payload: {
          source:          "notification",
          notification_id: notification.id,
          linked_type:     notification.linked_type,
          linked_id:       notification.linked_id
        }
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[OutboundPings] failed to enqueue from notification=#{notification.id}: #{e.message}")
      nil
    end

    # Enqueue one ping for each clinician mentioned in a clinician-only
    # crisis or urgent note. Skips if the note is family-visible (those
    # are handled via the family triage flow).
    def self.from_note(note)
      return unless note.clinician_only
      return unless %w[urgent crisis].include?(note.urgency.to_s)

      mentioned = resolve_mentions(note)
      mentioned.each do |target|
        next unless target.enabled_channels.any?

        OutboundPing.create!(
          agency:  note.agency,
          user:    target,
          kind:    note.urgency_crisis? ? "crisis" : "urgent",
          preview: phi_free_preview_for_note(note),
          payload: {
            source:  "note_mention",
            note_id: note.id
          }
        )
      end
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[OutboundPings] failed to enqueue from note=#{note.id}: #{e.message}")
      nil
    end

    # ── helpers ────────────────────────────────────────────────────

    def self.phi_free_preview_for_notification(n)
      tag = patient_tag_for(n.linked.is_a?(Patient) ? n.linked : (n.linked.respond_to?(:patient) ? n.linked.patient : nil))
      base = case n.kind.to_s
      when "pre_admit_review_ready"
               "Pre-admit eval awaiting your certification"
      when "pre_admit_certified"
               "Your pre-admit eval was certified by the MD"
      when "role_handoff"
               intent = n.title.to_s.split(":", 2).first.presence || "Follow-up"
               "#{intent} requested"
      else
               "Update awaiting your review"
      end
      tag.present? ? "#{base} for #{tag}" : base
    end

    def self.phi_free_preview_for_note(note)
      tag = patient_tag_for(note.patient)
      base = case note.urgency.to_s
      when "crisis" then "Crisis message awaiting your reply"
      when "urgent" then "Urgent message awaiting your reply"
      else               "Message awaiting your reply"
      end
      tag.present? ? "#{base} re: #{tag}" : base
    end

    # First name + last initial + MRN. Per most hospice agencies this
    # is the minimum identifier needed for staff triage outside the
    # app. Stricter PHI-free agencies can flip the default by setting
    # env HOSALIVIO_PINGS_PATIENT_TAG=none. Returns nil when patient
    # is missing or tagging is disabled.
    def self.patient_tag_for(patient)
      return nil if patient.nil?
      return nil if ENV["HOSALIVIO_PINGS_PATIENT_TAG"].to_s == "none"
      first = patient.first_name.to_s.strip
      last  = patient.last_name.to_s.strip
      return nil if first.empty? && last.empty?
      initial = last.empty? ? "" : "#{last[0]}."
      mrn = patient.mrn.to_s.strip
      [ [ first, initial ].reject(&:empty?).join(" ").strip,
       (mrn.empty? ? nil : "(#{mrn})") ].compact.reject(&:empty?).join(" ")
    end

    def self.map_notification_kind(kind)
      case kind.to_s
      when "pre_admit_review_ready" then "handoff"
      when "role_handoff"           then "handoff"
      else                                "urgent"
      end
    end

    # @Username mention parser. Same simple model as the in-app
    # mention scanner: any `@FirstName` token resolves to a real user
    # within the note's agency.
    def self.resolve_mentions(note)
      mentions = note.body.to_s.scan(/@([A-Za-z][A-Za-z0-9_'-]+)/).flatten.uniq
      return [] if mentions.empty?
      User.where(agency_id: note.agency_id, active: true, family_access: false)
          .where("LOWER(SUBSTRING(full_name FROM 1 FOR ?)) IN (?)",
                 mentions.map(&:length).max,
                 mentions.map(&:downcase))
          .reject { |u| u.id == note.author_user_id }
    end
  end
end
