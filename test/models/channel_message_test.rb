require "test_helper"

class ChannelMessageTest < ActiveSupport::TestCase
  setup do
    @agency = create_agency
    @author = create_user(agency: @agency, full_name: "Ada Admin", roles: %w[admin])
    @reggie = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    in_tenant(@agency) { Channel.ensure_defaults_for(@agency) }
    @general = in_tenant(@agency) { Channel.find_by(slug: "general") }
  end

  test "@-mention notifies the tagged teammate" do
    assert_difference -> { in_tenant(@agency) { Notification.where(user: @reggie, kind: "channel_mention").count } }, 1 do
      in_tenant(@agency) do
        @general.channel_messages.create!(agency: @agency, user: @author, body: "@Reggie please review the eval")
      end
    end
    note = in_tenant(@agency) { Notification.where(user: @reggie, kind: "channel_mention").last }
    assert_match "Ada Admin mentioned you in #general", note.title
  end

  test "no self-mention and unknown handles are ignored" do
    assert_no_difference -> { in_tenant(@agency) { Notification.where(kind: "channel_mention").count } } do
      in_tenant(@agency) do
        @general.channel_messages.create!(agency: @agency, user: @author, body: "note to self @Ada and @Nobody")
      end
    end
  end
end
