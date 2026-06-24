class AddIntervieweeToVisits < ActiveRecord::Migration[8.1]
  def change
    # Who the RN interviewed during the visit: the patient, the family, or both.
    # Captured in the pre-record wizard (consent -> type -> interviewee -> record).
    add_column :visits, :interviewee, :string
    add_column :visits, :interviewee_label, :string  # optional name(s) of who was interviewed
  end
end
