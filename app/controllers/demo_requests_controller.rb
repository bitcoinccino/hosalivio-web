# Public "Book a demo" lead capture for prospective partners. No auth — this
# is the top-of-funnel form on the landing page. Persists the lead; the team
# works the DemoRequest records (an admin inbox is a fast follow-up).
class DemoRequestsController < ApplicationController
  def new
    @demo_request = DemoRequest.new
  end

  def create
    # Honeypot: bots fill the hidden "company_site" field. Silently accept.
    if params[:company_site].present?
      return redirect_to(demo_path, notice: thanks_message)
    end

    @demo_request            = DemoRequest.new(demo_params)
    @demo_request.ip_address = request.remote_ip
    @demo_request.user_agent = request.user_agent.to_s.first(255)

    if @demo_request.save
      Rails.logger.info(
        "[DemoRequest] #{@demo_request.full_name} <#{@demo_request.work_email}> " \
        "org=#{@demo_request.organization.inspect} ehr=#{@demo_request.primary_ehr.inspect} " \
        "via=#{@demo_request.referral_display.inspect}"
      )
      redirect_to demo_path, notice: "Thanks, #{@demo_request.first_name}! #{thanks_message}"
    else
      flash.now[:alert] = @demo_request.errors.full_messages.to_sentence
      render :new, status: :unprocessable_entity
    end
  end

  private

  def thanks_message
    "Our partnerships lead will reach out within one business day."
  end

  def demo_params
    params.require(:demo_request).permit(
      :first_name, :last_name, :primary_ehr, :organization,
      :work_email, :phone, :referral_source, :referral_other
    )
  end
end
