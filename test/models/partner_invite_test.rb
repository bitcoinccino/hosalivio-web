require "test_helper"

class PartnerInviteTest < ActiveSupport::TestCase
  test "auto-generates a unique token on create" do
    a = PartnerInvite.create!
    b = PartnerInvite.create!
    assert a.token.present?
    assert_not_equal a.token, b.token
  end

  test "find_usable returns only unused, unexpired invites" do
    open    = PartnerInvite.create!
    expired = PartnerInvite.create!(expires_at: 1.hour.ago)
    used    = PartnerInvite.create!.tap { |i| i.consume!(create_agency) }

    assert_equal open, PartnerInvite.find_usable(open.token)
    assert_nil PartnerInvite.find_usable(expired.token)
    assert_nil PartnerInvite.find_usable(used.token)
    assert_nil PartnerInvite.find_usable("nope")
    assert_nil PartnerInvite.find_usable(nil)
  end

  test "consume! marks it used, links the agency, and blocks a second consume" do
    agency = create_agency
    invite = PartnerInvite.create!
    assert invite.usable?

    invite.consume!(agency)
    assert_not invite.usable?
    assert_equal agency, invite.agency
    assert invite.used_at.present?

    assert_raises(ActiveRecord::RecordInvalid) { invite.consume!(agency) }
  end

  test "signup_url embeds the token" do
    invite = PartnerInvite.create!
    url = invite.signup_url(host: "https://app.hosalivio.com/")
    assert_equal "https://app.hosalivio.com/partners/new?token=#{invite.token}", url
  end
end
