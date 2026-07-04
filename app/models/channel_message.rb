# A message in a team Channel. Not tied to a patient — this is the agency-wide
# team room, separate from the patient chart. Appends live to anyone viewing the
# channel via Turbo Streams.
class ChannelMessage < ApplicationRecord
  acts_as_tenant :agency

  belongs_to :agency
  belongs_to :channel
  belongs_to :user

  validates :body, presence: true, length: { maximum: 4000 }

  after_create_commit :broadcast_message
  after_create_commit :notify_mentioned_users

  private

  def broadcast_message
    broadcast_append_to(
      [ channel, :messages ],
      target:  "channel-#{channel_id}-messages",
      partial: "channel_messages/message",
      locals:  { message: self }
    )
  end

  # Ping teammates tagged with @Firstname in the body. Handles are matched
  # (case-insensitively) against the first name of active, non-family staff
  # in this agency; the author never notifies themselves, and @HosAlivio is
  # ignored. Notifications are in-app only (see Notification::IN_APP_ONLY_KINDS).
  def notify_mentioned_users
    handles = body.to_s.scan(/(?:^|\s)@(\w+)/).flatten.map(&:downcase).uniq
    handles.delete("hosalivio")
    return if handles.empty?

    User.unscoped
        .where(agency_id: agency_id, active: true, family_access: false)
        .where.not(id: user_id)
        .find_each do |u|
      first = u.full_name.to_s.split.first.to_s.downcase
      next if first.blank? || handles.exclude?(first)

      Notification.create!(
        agency:  agency,
        user:    u,
        kind:    "channel_mention",
        title:   "#{user.full_name} mentioned you in ##{channel.slug}",
        body:    body.to_s.truncate(140),
        linked:  self
      )
    end
  end
end
