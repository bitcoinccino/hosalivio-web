namespace :partners do
  desc "Print the gated partner-signup onboarding link. Usage: rake partners:signup_link HOST=https://app.hosalivio.com"
  task signup_link: :environment do
    token = PartnersController.signup_token
    if token.blank?
      warn "PARTNER_SIGNUP_TOKEN is not set — the wizard is closed. Set the env var (or :partner_signup_token credential) first."
      next
    end

    host = ENV["HOST"].presence || Rails.application.routes.default_url_options[:host] || "http://localhost:3000"
    host = host.chomp("/")
    puts "Send this to the agency AFTER their agreement is signed:"
    puts "#{host}/partners/new?token=#{token}"
  end
end
