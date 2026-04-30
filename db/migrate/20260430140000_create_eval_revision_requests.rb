class CreateEvalRevisionRequests < ActiveRecord::Migration[8.1]
  # Captures one round trip when an MD reviewing a finalized
  # pre-admit eval asks the RN to revise something. Each row is a
  # standalone audit fact (who requested, when, why, and a snapshot
  # hash of the eval state at that moment) so a CMS auditor can
  # reconstruct the back-and-forth without sifting through ad-hoc
  # notes. Resolved when the RN re-routes to MD; we stamp
  # resolved_at then.
  def change
    create_table :eval_revision_requests, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :pre_admit_eval, type: :uuid, null: false, foreign_key: true, index: true
      t.references :requester,      type: :uuid, null: false, index: true   # MD who sent it back
      t.text       :comment,        null: false
      t.string     :document_hash
      t.datetime   :resolved_at
      t.timestamps
    end
  end
end
