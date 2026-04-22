# After an Inquiry is created, fan out the signal:
#   1. stamp Current so the AgentEvent flows through AgentAuditable cleanly
#   2. emit an AgentEvent("inquiry_received") so it broadcasts to Mission Stage
#      via the existing mission_stage_payload + Cable pipe.
#
# Everything below runs inside the create-commit callback of Inquiry, so it
# piggybacks on the same transaction the Inquiry was saved in.

class InquiryProcessor
  def initialize(inquiry)
    @inquiry = inquiry
  end

  def call
    return unless @inquiry.agency

    original_agency = Current.agency
    original_agent  = Current.agent_id
    original_sess   = Current.agent_session_id

    Current.agency           = @inquiry.agency
    Current.agent_id         = "admissions"
    Current.agent_session_id = "lucia-inquiry-#{SecureRandom.hex(4)}"

    # Resolve which branch inside this agency should own the inquiry based on
    # the caller's ZIP. Lucia reads this off the AgentEvent and routes the
    # admission conversation into that branch's queue.
    routed_branch = Branch.route_for_zip(@inquiry.agency, @inquiry.zip)

    AgentEvent.create!(
      agency:           @inquiry.agency,
      agent_id:         "admissions",
      agent_session_id: Current.agent_session_id,
      action:           "inquiry_received",
      subject:          @inquiry,
      change_set: {
        is_general:       @inquiry.is_general,
        source_prompt:    @inquiry.source_prompt,
        routed_to_role:   @inquiry.routed_to_role,
        zip_prefix:       @inquiry.zip_prefix,
        first_name:       @inquiry.first_name,
        routed_branch_id: routed_branch&.id,
        routed_branch:    routed_branch&.name
      },
      happened_at: Time.current
    )
  ensure
    Current.agency           = original_agency
    Current.agent_id         = original_agent
    Current.agent_session_id = original_sess
  end
end
