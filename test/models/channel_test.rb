require "test_helper"

class ChannelTest < ActiveSupport::TestCase
  setup do
    @agency = create_agency
    @admin  = create_user(agency: @agency, full_name: "Ada Admin",  roles: %w[admin])
    @rn     = create_user(agency: @agency, full_name: "Reggie RN",  roles: %w[rn])
    @aide   = create_user(agency: @agency, full_name: "Andy Aide",  roles: %w[aide])
    in_tenant(@agency) { Channel.ensure_defaults_for(@agency) }
    @general   = in_tenant(@agency) { Channel.find_by(slug: "general") }
    @admission = in_tenant(@agency) { Channel.find_by(slug: "admission") }
  end

  test "ensure_defaults_for provisions General + Admission, idempotently" do
    in_tenant(@agency) { Channel.ensure_defaults_for(@agency) }   # second call adds nothing
    assert_equal %w[admission general], in_tenant(@agency) { Channel.order(:slug).pluck(:slug) }
    assert @general.system?
    assert_equal %w[admin don rn md admissions], @admission.post_roles
  end

  test "#general is open to all staff for posting" do
    assert @general.postable_by?(@aide)
    assert @general.postable_by?(@rn)
  end

  test "#admission is post-restricted to the core team; others read-only" do
    assert @admission.postable_by?(@rn),    "RN is core"
    assert @admission.postable_by?(@admin), "admin is core"
    assert_not @admission.postable_by?(@aide), "aide cannot post"
    assert @admission.readable_by?(@aide),  "aide can still read"
  end

  test "only admins can manage channels" do
    assert @admission.manageable_by?(@admin)
    assert_not @admission.manageable_by?(@rn)
  end
end
