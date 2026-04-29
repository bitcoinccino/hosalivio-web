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
      case n.kind.to_s
      when "pre_admit_review_ready"
        "1 pre-admit eval awaiting your certification"
      when "pre_admit_certified"
        "Your pre-admit eval was certified by the MD"
      when "role_handoff"
        intent = n.title.to_s.split(":", 2).first.presence || "follow-up"
        "#{intent} requested for 1 patient"
      else
        "1 update awaiting your review"
      end
    end

    def self.phi_free_preview_for_note(note)
      case note.urgency.to_s
      when "crisis" then "Crisis-level message awaiting your reply"
      when "urgent" then "Urgent message awaiting your reply"
      else               "1 message awaiting your reply"
      end
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
