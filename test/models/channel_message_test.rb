require "test_helper"
require "stringio"

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

  test "a reply threads under its root parent" do
    root  = in_tenant(@agency) { @general.channel_messages.create!(agency: @agency, user: @author, body: "root msg") }
    reply = in_tenant(@agency) { @general.channel_messages.create!(agency: @agency, user: @reggie, body: "a reply", parent: root) }
    assert reply.reply?
    assert_equal [ reply.id ], in_tenant(@agency) { root.replies.pluck(:id) }
  end

  test "threading is only one level deep" do
    root  = in_tenant(@agency) { @general.channel_messages.create!(agency: @agency, user: @author, body: "root msg") }
    reply = in_tenant(@agency) { @general.channel_messages.create!(agency: @agency, user: @reggie, body: "a reply", parent: root) }
    nested = in_tenant(@agency) { @general.channel_messages.new(agency: @agency, user: @author, body: "nope", parent: reply) }
    assert_not nested.valid?
  end

  test "a voice note may have a blank body when audio is attached" do
    in_tenant(@agency) do
      msg = @general.channel_messages.new(agency: @agency, user: @author, body: "")
      msg.audio.attach(io: StringIO.new("fake-audio"), filename: "v.webm", content_type: "audio/webm")
      assert msg.valid?, msg.errors.full_messages.to_sentence
    end
  end

  test "a message with neither body nor audio is invalid" do
    in_tenant(@agency) do
      msg = @general.channel_messages.new(agency: @agency, user: @author, body: "")
      assert_not msg.valid?
    end
  end

  test "no self-mention and unknown handles are ignored" do
    assert_no_difference -> { in_tenant(@agency) { Notification.where(kind: "channel_mention").count } } do
      in_tenant(@agency) do
        @general.channel_messages.create!(agency: @agency, user: @author, body: "note to self @Ada and @Nobody")
      end
    end
  end
end
