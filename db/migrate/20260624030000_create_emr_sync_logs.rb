class CreateEmrSyncLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :emr_sync_logs, id: :uuid do |t|
      t.references :pre_admit_eval, null: false, foreign_key: true, type: :uuid
      t.references :agency,         null: false, foreign_key: true, type: :uuid

      # External target + transmission lifecycle.
      #   status: pending → processing → synchronized | failed
      t.string   :target_system,        null: false, default: "VITAS_PORTAL"
      t.string   :status,               null: false, default: "pending"
      t.string   :external_encounter_id
      t.jsonb    :payload_sent
      t.jsonb    :response_received
      t.integer  :retry_count,          null: false, default: 0
      t.datetime :synchronized_at

      t.timestamps
    end

    # One log per (eval, target): the sync job's find_or_create_by leans on
    # this so a double-tap / retry can't open twin transmissions for the same
    # encounter (mirrors idx_one_pre_admit_eval_per_visit's intent).
    add_index :emr_sync_logs, [ :pre_admit_eval_id, :target_system ],
              unique: true, name: "idx_one_sync_log_per_eval_target"

    # Mirror the lifecycle onto the eval for cheap list/filter queries.
    #   not_synced → processing → synced | failed
    add_column :pre_admit_evals, :sync_status, :integer, null: false, default: 0
  end
end
