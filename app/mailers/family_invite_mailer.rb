class FamilyInviteMailer < ApplicationMailer
  # Triggered when a clinician invites a family member to a patient chart.
  #
  # Params: user, patient, temp_password, invited_by
  def welcome
    @user          = params[:user]
    @patient       = params[:patient]
    @temp_password = params[:temp_password]
    @invited_by    = params[:invited_by]

    from_addr = @patient.agency&.slug&.presence&.then { |s| "no-reply@#{s.downcase}.hosalivio.com" } ||
                "no-reply@hosalivio.com"

    mail(
      to:      @user.email,
      from:    from_addr,
      subject: "You've been added to #{@patient.first_name}'s care team"
    )
  end
end
