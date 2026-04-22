class AddAgentPersonasToAgencies < ActiveRecord::Migration[8.1]
  def change
    change_table :agencies, bulk: true do |t|
      # Per-agency customization for shared role archetypes.
      # agent_personas keys by role: "admissions" => {display_name, voice_notes, phone, credentials, ...}
      t.jsonb :agent_personas,  null: false, default: {}
      # agent_overrides keys by role: "admissions" => "Extra rules that apply only to this agency."
      t.jsonb :agent_overrides, null: false, default: {}
    end
  end
end
