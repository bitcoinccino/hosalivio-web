class EnforceOneEvalPerVisit < ActiveRecord::Migration[8.1]
  def change
    # At most one pre-admit eval per visit. Partial (visit_id is NULL for
    # unclaimed drafts) so it constrains only linked evals. Prevents the
    # duplicate-eval rows that caused a FK violation on visit discard.
    add_index :pre_admit_evals, :visit_id,
              unique: true,
              where:  "visit_id IS NOT NULL",
              name:   "idx_one_pre_admit_eval_per_visit"
  end
end
