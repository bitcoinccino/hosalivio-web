class AddVeteranBranchToPatients < ActiveRecord::Migration[8.1]
  def change
    # Branch of military service, captured only when the patient is a veteran
    # (revealed dynamically on the admissions form). Supports VA benefit work.
    add_column :patients, :veteran_branch, :string
  end
end
