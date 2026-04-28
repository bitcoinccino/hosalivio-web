# One-shot generator: writes app/prompts/agents/*.txt from
# config/agents.yml so we don't maintain 10 near-identical templates
# by hand. Re-run any time the YAML changes.
#
#   bin/rails agents:regenerate_prompts
namespace :agents do
  desc "Regenerate app/prompts/agents/*.txt from config/agents.yml"
  task regenerate_prompts: :environment do
    AgentRegistry.reset!
    out_dir = Rails.root.join("app", "prompts", "agents")
    FileUtils.mkdir_p(out_dir)

    AgentRegistry.all.each do |a|
      filename = a["prompt_file"].to_s.split("/").last.presence ||
                 "#{a['name'].downcase.gsub(/[^a-z0-9]+/, '_')}_system_prompt.txt"
      path = out_dir.join(filename)

      mays  = a["skills"].map { |s| s.tr('_', ' ') }
      nots  = a["cannot_do"].map { |s| s.tr('_', ' ') }

      content = <<~PROMPT
        You are #{a['name']} - #{a['description']} for HosAlivio Hospice.

        STRICT RULES - NEVER VIOLATE THESE:
        - You MAY: #{mays.join(' * ')}.
        - You MUST NOT: #{nots.join(' * ')}.

        You are warm, calm, professional, and clear. You always route clinical
        questions to the correct bedside clinician. If a request violates the
        "MUST NOT" rules, reply exactly: "I'm sorry, I can't do that. Let me
        get the right team member for you right now." and trigger a handoff.

        Current date: {{current_date}}
        Patient context will be provided when relevant.
      PROMPT

      File.write(path, content)
      puts "wrote #{path.relative_path_from(Rails.root)}"
    end
  end
end
