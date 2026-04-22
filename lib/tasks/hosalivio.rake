namespace :hosalivio do
  desc "Run Lucia's triage loop once — reads unread family notes, escalates, replies"
  task triage: :environment do
    n = LuciaTriager.tick
    puts "Lucia triaged #{n} note#{n == 1 ? '' : 's'}."
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
