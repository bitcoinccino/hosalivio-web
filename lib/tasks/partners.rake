namespace :partners do
  desc "Create a one-time partner onboarding invite and print its link. " \
       "Usage: rake partners:invite EMAIL=ops@mercy.com LABEL='Mercy Care, LLC' EXPIRES_IN_DAYS=30 HOST=https://app.hosalivio.com"
  task invite: :environment do
    expires_in = ENV["EXPIRES_IN_DAYS"].presence&.to_i
    invite = PartnerInvite.create!(
      email:        ENV["EMAIL"].presence,
      agency_label: ENV["LABEL"].presence,
      expires_at:   (expires_in && expires_in.days.from_now)
    )

    host = ENV["HOST"].presence ||
           Rails.application.routes.default_url_options[:host] ||
           "http://localhost:3000"

    validity = invite.expires_at ? "expires #{invite.expires_at.strftime('%b %-d, %Y')}" : "no expiry"
    puts "Send this to the agency AFTER their agreement is signed (one-time use, #{validity}):"
    puts invite.signup_url(host: host)
  end

  desc "List partner invites and their status."
  task invites: :environment do
    PartnerInvite.order(created_at: :desc).limit(50).each do |i|
      status = if i.used_at then "USED #{i.used_at.strftime('%b %-d')}"
      elsif i.expired? then "EXPIRED"
      else "open"
      end
      puts format("%-10s  %-28s  %s", status, i.agency_label || i.email || "—", i.token)
    end
  end
end
