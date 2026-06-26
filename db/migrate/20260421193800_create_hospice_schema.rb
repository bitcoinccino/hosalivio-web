class CreateHospiceSchema < ActiveRecord::Migration[8.1]
  def change
    # --------------------------------------------------------------------------
    # Roles are GLOBAL (same vocabulary across all agencies) — not agency-scoped.
    # --------------------------------------------------------------------------
    create_table :roles, id: :uuid do |t|
      t.string :name,  null: false   # e.g. "rn", "md", "don"
      t.string :label, null: false   # e.g. "Registered Nurse"
      t.timestamps
    end
    add_index :roles, :name, unique: true

    # --------------------------------------------------------------------------
    # user_roles — which roles a user holds, scoped to an agency.
    # agency_id denormalized here so acts_as_tenant can scope directly.
    # --------------------------------------------------------------------------
    create_table :user_roles, id: :uuid do |t|
      t.references :user,   type: :uuid, foreign_key: true, null: false
      t.references :role,   type: :uuid, foreign_key: true, null: false
      t.references :agency, type: :uuid, foreign_key: true, null: false
      t.timestamps
    end
    add_index :user_roles, [ :user_id, :role_id, :agency_id ], unique: true,
              name: "idx_user_roles_on_user_role_agency"

    # --------------------------------------------------------------------------
    # Patients — the core clinical record. PHI fields encrypted at app layer.
    # --------------------------------------------------------------------------
    create_table :patients, id: :uuid do |t|
      t.references :agency, type: :uuid, foreign_key: true, null: false

      t.string :mrn, null: false      # human-readable, e.g. "HOS-00001" — unique per agency

      # Demographics (encrypted via Active Record Encryption at model layer)
      t.string :first_name,         null: false
      t.string :last_name,          null: false
      t.string :dob,                null: false   # stored encrypted; cast to Date via `attribute :dob, :date` in model
      t.string :gender
      t.string :preferred_language, null: false, default: "en"

      # Contact (encrypted)
      t.string :address_line1
      t.string :address_line2
      t.string :city
      t.string :state
      t.string :zip
      t.string :phone
      t.string :email

      # Clinical (encrypted)
      t.string :primary_diagnosis
      t.text   :secondary_diagnoses
      t.jsonb  :allergies, null: false, default: []

      # Hospice benefit / certification
      t.date    :hospice_election_date
      t.integer :benefit_period               # enum: bp1_90=0, bp2_90=1, bp3_60n=2
      t.date    :cert_period_start
      t.date    :cert_period_end

      # Status + code status — non-negotiable hospice fields
      t.integer :status,      null: false, default: 0  # referred=0, admitted=1, active=2, revoked=3, discharged=4, deceased=5
      t.integer :code_status, null: false, default: 0  # full_code=0, dnr=1, dni=2, dnr_dni=3, comfort_only=4
      t.boolean :advance_directive_on_file, null: false, default: false
      t.boolean :polst_on_file,             null: false, default: false

      # Care team assignments
      t.references :assigned_rn,       type: :uuid, foreign_key: { to_table: :users }, null: true
      t.references :assigned_md,       type: :uuid, foreign_key: { to_table: :users }, null: true
      t.references :assigned_sw,       type: :uuid, foreign_key: { to_table: :users }, null: true
      t.references :assigned_chaplain, type: :uuid, foreign_key: { to_table: :users }, null: true

      # Primary caregiver (encrypted)
      t.string :caregiver_name
      t.string :caregiver_phone

      t.timestamps
    end
    # MRN unique per agency
    add_index :patients, [ :agency_id, :mrn ], unique: true, name: "idx_patients_on_agency_mrn"
    add_index :patients, [ :agency_id, :status ]
    add_index :patients, [ :agency_id, :code_status ]

    # Now add patient_id to users (family portal users gated to one patient)
    add_reference :users, :patient, type: :uuid, foreign_key: true, null: true

    # --------------------------------------------------------------------------
    # Visits — any discipline's visit to a patient. Billing pulls from here.
    # --------------------------------------------------------------------------
    create_table :visits, id: :uuid do |t|
      t.references :agency,  type: :uuid, foreign_key: true, null: false
      t.references :patient, type: :uuid, foreign_key: true, null: false
      t.references :user,    type: :uuid, foreign_key: true, null: false  # clinician

      t.integer  :discipline, null: false  # enum mirrors role: rn, md, sw, chaplain, aide, don
      t.integer  :visit_type, null: false, default: 0
      # visit_type enum: routine=0, admission=1, recert=2, face_to_face=3, discharge=4, death=5

      t.datetime :scheduled_at
      t.datetime :started_at
      t.datetime :ended_at

      t.text    :narrative                 # encrypted
      t.jsonb   :vitals, null: false, default: {}
      t.integer :pain_score                 # 0-10

      t.boolean :billable, null: false, default: true
      t.string  :visit_code                 # billing code when billable

      t.timestamps
    end
    add_index :visits, [ :agency_id, :patient_id, :started_at ],
              name: "idx_visits_on_agency_patient_start"
    add_index :visits, [ :agency_id, :visit_type ],
              name: "idx_visits_on_agency_visit_type"

    # --------------------------------------------------------------------------
    # Medication orders — prescribed by MD.
    # --------------------------------------------------------------------------
    create_table :medication_orders, id: :uuid do |t|
      t.references :agency,  type: :uuid, foreign_key: true, null: false
      t.references :patient, type: :uuid, foreign_key: true, null: false
      t.references :prescribed_by, type: :uuid, foreign_key: { to_table: :users }, null: false

      t.string  :drug_name,       null: false
      t.string  :dose,            null: false    # e.g. "5mg"
      t.integer :route,           null: false    # enum: po=0, sl=1, sc=2, iv=3, im=4, pr=5, top=6, neb=7, other=8
      t.string  :frequency,       null: false    # e.g. "q4h prn"
      t.boolean :prn,             null: false, default: false
      t.string  :prn_indication
      t.date    :start_date,      null: false
      t.date    :end_date
      t.integer :status,          null: false, default: 0  # active=0, dc=1, hold=2

      t.timestamps
    end
    add_index :medication_orders, [ :agency_id, :patient_id, :status ]

    # --------------------------------------------------------------------------
    # Medication logs — each administration event.
    # --------------------------------------------------------------------------
    create_table :medication_logs, id: :uuid do |t|
      t.references :agency,            type: :uuid, foreign_key: true, null: false
      t.references :medication_order,  type: :uuid, foreign_key: true, null: false
      t.references :administered_by,   type: :uuid, foreign_key: { to_table: :users }, null: false

      t.datetime :administered_at, null: false
      t.string   :dose_given,      null: false
      t.boolean  :effective                          # nullable: unknown immediately
      t.text     :side_effects
      t.integer  :source, null: false, default: 0   # comfort_kit=0, home_supply=1, pharmacy_delivery=2

      t.timestamps
    end
    add_index :medication_logs, [ :agency_id, :administered_at ]

    # --------------------------------------------------------------------------
    # Pharmacy deliveries — comfort kits, refills, emergency drops.
    # --------------------------------------------------------------------------
    create_table :pharmacy_deliveries, id: :uuid do |t|
      t.references :agency,  type: :uuid, foreign_key: true, null: false
      t.references :patient, type: :uuid, foreign_key: true, null: false
      t.references :medication_order, type: :uuid, foreign_key: true, null: true  # nullable for comfort kits
      t.references :confirmed_by,     type: :uuid, foreign_key: { to_table: :users }, null: true

      t.integer  :kind,   null: false    # comfort_kit=0, refill=1, new_fill=2, emergency=3
      t.integer  :status, null: false, default: 0  # requested=0, en_route=1, delivered=2, refused=3
      t.datetime :delivered_at

      t.timestamps
    end
    add_index :pharmacy_deliveries, [ :agency_id, :patient_id, :status ]

    # --------------------------------------------------------------------------
    # DME orders — hospital beds, O2, wheelchairs, etc.
    # --------------------------------------------------------------------------
    create_table :dme_orders, id: :uuid do |t|
      t.references :agency,  type: :uuid, foreign_key: true, null: false
      t.references :patient, type: :uuid, foreign_key: true, null: false

      t.integer  :equipment_type, null: false
      # enum: hospital_bed=0, o2_concentrator=1, wheelchair=2, bsc=3, hoyer_lift=4,
      #       walker=5, shower_chair=6, suction_machine=7, nebulizer=8, cpap=9, other=10
      t.integer  :quantity,       null: false, default: 1
      t.string   :vendor
      t.integer  :status,         null: false, default: 0  # requested=0, approved=1, delivered=2, picked_up=3, returned=4
      t.datetime :requested_at,   null: false
      t.datetime :delivered_at
      t.datetime :picked_up_at
      t.text     :notes

      t.timestamps
    end
    add_index :dme_orders, [ :agency_id, :patient_id, :status ]

    # --------------------------------------------------------------------------
    # Agent events — audit trail for agent-driven changes.
    # Complements PaperTrail (which tracks human whodunnit).
    # --------------------------------------------------------------------------
    create_table :agent_events, id: :uuid do |t|
      t.references :agency, type: :uuid, foreign_key: true, null: false

      t.string  :agent_id,         null: false   # e.g. "rn", "md", "admission_coordinator"
      t.string  :agent_session_id                  # OpenClaw session UUID, stamped from X-OpenClaw-Session-Id header
      t.string  :action,           null: false   # create / update / destroy / broadcast

      # Polymorphic subject — patient, visit, medication_order, etc.
      t.references :subject, polymorphic: true, type: :uuid, null: true

      t.jsonb    :change_set, null: false, default: {}
      t.datetime :happened_at, null: false

      t.timestamps
    end
    add_index :agent_events, [ :agency_id, :agent_id, :happened_at ],
              name: "idx_agent_events_on_agency_agent_time"
    add_index :agent_events, [ :agency_id, :happened_at ]
  end
end
