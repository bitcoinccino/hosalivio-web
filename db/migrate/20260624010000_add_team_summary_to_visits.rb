class AddTeamSummaryToVisits < ActiveRecord::Migration[8.1]
  def change
    # AI-generated care-team handoff summary (1-3 lines) shown on the Team tab.
    add_column :visits, :team_summary, :text
  end
end
