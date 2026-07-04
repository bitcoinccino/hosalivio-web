require "test_helper"

class ChannelsFlowTest < ActionDispatch::IntegrationTest
  setup do
    @agency = create_agency
    @rn     = create_user(agency: @agency, full_name: "Reggie RN", roles: %w[rn])
    @aide   = create_user(agency: @agency, full_name: "Andy Aide", roles: %w[aide])
    in_tenant(@agency) { Channel.ensure_defaults_for(@agency) }
  end

  test "index lands on #general and lists the channels" do
    sign_in @rn
    get channels_path
    assert_response :success
    assert_match "# General", response.body     # default channel header
    assert_match "admission", response.body      # in the channel list
  end

  test "a core-team member can post to #admission" do
    sign_in @rn
    assert_difference -> { in_tenant(@agency) { ChannelMessage.count } }, 1 do
      post channel_messages_path("admission"), params: { body: "Maria's eval is ready for MD cert." }
    end
    assert_redirected_to channel_path("admission")
  end

  test "a non-core member reads #admission but cannot post" do
    sign_in @aide
    get channel_path("admission")
    assert_response :success
    assert_match "only its team can post", response.body

    assert_no_difference -> { in_tenant(@agency) { ChannelMessage.count } } do
      post channel_messages_path("admission"), params: { body: "hi" }
    end
    assert_match "only its team can post", flash[:alert].to_s
  end

  test "any staff member can post to #general" do
    sign_in @aide
    assert_difference -> { in_tenant(@agency) { ChannelMessage.count } }, 1 do
      post channel_messages_path("general"), params: { body: "morning, team" }
    end
  end

  test "posting from the dashboard returns to the dashboard, not the channel" do
    sign_in @rn
    post channel_messages_path("general"), params: { body: "quick note", return_to: "dashboard" }
    assert_redirected_to dashboard_path
  end
end
