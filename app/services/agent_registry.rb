# Single read interface over config/agents.yml. Caches the parsed
# capability matrix at boot so the lookups are constant-time.
#
# Used by:
#   - HosalivioTriager (resolves role -> persona name + label for
#     the Notified header in audit traces)
#   - AgentGuard (validates a proposed action against cannot_do)
#   - AgentBrain prompt composition (loads the prompt template
#     listed in prompt_file)
#   - Mission Stage / EventNarrator (persona display)
#
# Lookup style:
#   AgentRegistry.by_role("rn")              # full hash for Pascal
#   AgentRegistry.persona_for("rn")          # "Pascal"
#   AgentRegistry.skills_for("rn")           # [...]
#   AgentRegistry.cannot_do_for("md")        # [...]
#   AgentRegistry.prompt_for("admissions")   # contents of the prompt
#                                             txt with {{vars}} interpolated
#   AgentRegistry.role_for_name("Diaphnie")  # "don"

class AgentRegistry
  CONFIG_PATH = Rails.root.join("config", "agents.yml")

  class << self
    def all
      @all ||= load_config["agents"].map(&:freeze).freeze
    end

    # Reset the in-memory cache. Useful in dev when editing the YAML
    # without restarting the server, and from the test suite.
    def reset!
      @all = nil
      @by_role = nil
      @by_name = nil
    end

    def by_role(role)
      @by_role ||= all.index_by { |a| a["role"] }
      @by_role[role.to_s]
    end

    def by_name(name)
      @by_name ||= all.index_by { |a| a["name"] }
      @by_name[name.to_s]
    end

    def persona_for(role)        ; by_role(role)&.fetch("name", role.to_s.humanize); end
    def description_for(role)    ; by_role(role)&.fetch("description", ""); end
    def skills_for(role)         ; Array(by_role(role)&.fetch("skills", [])); end
    def cannot_do_for(role)      ; Array(by_role(role)&.fetch("cannot_do", [])); end
    def triage_priority_for(role); by_role(role)&.fetch("triage_priority", 999); end

    def role_for_name(name)
      by_name(name)&.fetch("role", nil)
    end

    # Loads the prompt template listed in the agent's prompt_file
    # entry, with mustache-style {{var}} placeholders interpolated
    # from the supplied context hash. Falls back to a generic prompt
    # when the file isn't present yet.
    def prompt_for(role, context: {})
      agent = by_role(role)
      return generic_prompt(role) unless agent
      file = agent["prompt_file"].to_s
      return generic_prompt(role) if file.empty?
      path = Rails.root.join("app", "prompts", file)
      return generic_prompt(role) unless File.exist?(path)
      tmpl = File.read(path)
      interpolate(tmpl, default_context.merge(context.stringify_keys))
    end

    # Used by triage rankers when scoring which agent best matches a
    # message. Returns the count of skill keywords that appear in the
    # message text (case-insensitive). Lightweight; the LLM brain is
    # the smarter classifier.
    def skill_match_score(role, message)
      msg = message.to_s.downcase
      skills_for(role).count { |skill| msg.include?(skill.tr("_", " ")) }
    end

    private

    def load_config
      YAML.safe_load_file(CONFIG_PATH, permitted_classes: [ Symbol ]).deep_dup
    end

    def default_context
      { "current_date" => Date.current.iso8601 }
    end

    def interpolate(tmpl, ctx)
      tmpl.gsub(/\{\{\s*(\w+)\s*\}\}/) { ctx[$1].to_s }
    end

    def generic_prompt(role)
      <<~PROMPT
        You are #{persona_for(role)} - #{description_for(role)} for HosAlivio Hospice.

        STRICT RULES - NEVER VIOLATE THESE:
        - You MAY: #{skills_for(role).join(' * ')}.
        - You MUST NOT: #{cannot_do_for(role).join(' * ')}.

        You are warm, calm, professional, and clear. You always route clinical
        questions to the correct bedside clinician. If a request violates the
        "MUST NOT" rules, reply exactly: "I'm sorry, I can't do that. Let me
        get the right team member for you right now." and trigger a handoff.

        Current date: #{Date.current.iso8601}
        Patient context will be provided when relevant.
      PROMPT
    end
  end
end
