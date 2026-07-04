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

  private

  def broadcast_message
    broadcast_append_to(
      [ channel, :messages ],
      target:  "channel-#{channel_id}-messages",
      partial: "channel_messages/message",
      locals:  { message: self }
    )
  end
end
