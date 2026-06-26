class VisitReminderMailer < ApplicationMailer
  # Sent immediately when a visit is scheduled and assigned to a clinician,
  # so the assigned RN learns about it now instead of waiting for the 24h
  # reminder. Triggered from VisitsController#create via the model.
  def assigned
    @visit     = params[:visit]
    @user      = @visit.user
    @patient   = @visit.patient
    @scheduler = params[:scheduled_by]

    return if @user&.email.blank?

    mail(
      to:      @user.email,
      subject: "New visit assigned: #{@patient&.full_name} — #{@visit.anchor_start&.strftime('%a %b %-d, %-l:%M %p')}"
    )
  end

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
