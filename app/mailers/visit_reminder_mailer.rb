class VisitReminderMailer < ApplicationMailer
  def tomorrow_reminder
    @visit   = params[:visit]
    @user    = @visit.user
    @patient = @visit.patient

    return if @user&.email.blank?

    mail(
      to:      @user.email,
      subject: "Tomorrow #{@visit.anchor_start&.strftime('%-l:%M %p')} — #{@patient&.full_name}"
    )
  end
end
