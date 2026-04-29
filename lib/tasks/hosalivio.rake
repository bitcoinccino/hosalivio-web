namespace :hosalivio do
  desc "Run HosAlivio's triage loop once — reads unread family notes, escalates, replies"
  task triage: :environment do
    n = HosalivioTriager.tick
    puts "HosAlivio triaged #{n} note#{n == 1 ? '' : 's'}."
  end

  desc "Enqueue recert reminders for assigned RNs at 7/3/1/0-day milestones. Run daily via cron."
  task recert_reminders: :environment do
    n = RecertReminders.run_today
    puts "Enqueued #{n} recert reminder ping#{n == 1 ? '' : 's'} for #{Date.current.iso8601}."
  end

  desc "Print API tokens for each agent role (for the first agency)"
  task tokens: :environment do
    agency = Agency.first
    abort "No agency found. Run: bin/rails db:seed" if agency.nil?

    puts ""
    puts "Agency: #{agency.name} (#{agency.slug} / #{agency.id})"
    puts "Use the tokens below in OpenClaw agent env, e.g. HOSALIVIO_RN_TOKEN."
    puts "-" * 80

    Role.order(:name).each do |role|
      token = AgentToken.encode(role: role.name, agency_id: agency.id)
      env_name = "HOSALIVIO_#{role.name.upcase}_TOKEN"
      puts "#{env_name}:"
      puts "  #{token}"
      puts ""
    end
  end
end
