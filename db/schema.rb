# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_23_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.uuid "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "agencies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "accepting_referrals", default: true, null: false
    t.boolean "active", default: true, null: false
    t.string "address_line1"
    t.string "address_line2"
    t.jsonb "agent_overrides", default: {}, null: false
    t.jsonb "agent_personas", default: {}, null: false
    t.integer "billing_tier", default: 0, null: false
    t.text "bio"
    t.string "city"
    t.datetime "created_at", null: false
    t.string "emoji", default: "🩺", null: false
    t.jsonb "features", default: {}, null: false
    t.string "hero_color", default: "#D97757", null: false
    t.jsonb "insurance_accepted", default: [], null: false
    t.boolean "is_partner", default: false, null: false
    t.jsonb "languages", default: ["en"], null: false
    t.string "medicare_provider_number"
    t.string "name", null: false
    t.string "npi"
    t.string "phone"
    t.integer "response_sla_hours", default: 24, null: false
    t.jsonb "service_area_zips", default: [], null: false
    t.string "slug", null: false
    t.jsonb "specialties", default: [], null: false
    t.string "state"
    t.datetime "updated_at", null: false
    t.string "zip"
    t.index ["accepting_referrals"], name: "index_agencies_on_accepting_referrals"
    t.index ["features"], name: "index_agencies_on_features", using: :gin
    t.index ["is_partner"], name: "index_agencies_on_is_partner"
    t.index ["medicare_provider_number"], name: "idx_agencies_on_medicare_number", unique: true, where: "(medicare_provider_number IS NOT NULL)"
    t.index ["npi"], name: "index_agencies_on_npi", unique: true, where: "(npi IS NOT NULL)"
    t.index ["slug"], name: "index_agencies_on_slug", unique: true
  end

  create_table "agent_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "agency_id", null: false
    t.string "agent_id", null: false
    t.string "agent_session_id"
    t.jsonb "change_set", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "happened_at", null: false
    t.uuid "subject_id"
    t.string "subject_type"
    t.datetime "updated_at", null: false
    t.index ["agency_id", "agent_id", "happened_at"], name: "idx_agent_events_on_agency_agent_time"
    t.index ["agency_id", "happened_at"], name: "index_agent_events_on_agency_id_and_happened_at"
    t.index ["agency_id"], name: "index_agent_events_on_agency_id"
    t.index ["subject_type", "subject_id"], name: "index_agent_events_on_subject"
  end

  create_table "branches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "after_hours_phone"
    t.uuid "agency_id", null: false
    t.integer "branch_type", default: 0, null: false
    t.string "ccn"
    t.string "city"
    t.uuid "clinical_supervisor_id"
    t.datetime "created_at", null: false
    t.uuid "director_of_nursing_id"
    t.string "ein"
    t.uuid "manager_id"
    t.uuid "medical_director_id"
    t.string "name", null: false
    t.string "npi", limit: 10
    t.string "phone"
    t.jsonb "service_area_counties", default: [], null: false
    t.jsonb "service_area_zips", default: [], null: false
    t.string "state"
    t.string "state_license_number"
    t.string "timezone", default: "America/New_York", null: false
    t.string "triage_email"
    t.datetime "updated_at", null: false
    t.string "zip"
    t.index ["agency_id", "name"], name: "index_branches_on_agency_id_and_name", unique: true
    t.index ["agency_id"], name: "index_branches_on_agency_id"
    t.index ["ccn"], name: "index_branches_on_ccn", unique: true, where: "(ccn IS NOT NULL)"
    t.index ["clinical_supervisor_id"], name: "index_branches_on_clinical_supervisor_id"
    t.index ["director_of_nursing_id"], name: "index_branches_on_director_of_nursing_id"
    t.index ["manager_id"], name: "index_branches_on_manager_id"
    t.index ["medical_director_id"], name: "index_branches_on_medical_director_id"
    t.index ["npi"], name: "index_branches_on_npi", unique: true, where: "(npi IS NOT NULL)"
    t.index ["service_area_counties"], name: "index_branches_on_service_area_counties", using: :gin
    t.index ["service_area_zips"], name: "index_branches_on_service_area_zips", using: :gin
  end

  create_table "dme_orders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.integer "equipment_type", null: false
    t.text "notes"
    t.uuid "patient_id", null: false
    t.datetime "picked_up_at"
    t.integer "quantity", default: 1, null: false
    t.datetime "requested_at", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "vendor"
    t.index ["agency_id", "patient_id", "status"], name: "index_dme_orders_on_agency_id_and_patient_id_and_status"
    t.index ["agency_id"], name: "index_dme_orders_on_agency_id"
    t.index ["patient_id"], name: "index_dme_orders_on_patient_id"
  end

  create_table "icd10_explanations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "category"
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.string "hospice_context"
    t.string "simple_description", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_icd10_explanations_on_code", unique: true
  end

  create_table "inquiries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.datetime "claimed_at"
    t.uuid "claimed_by_id"
    t.string "contact"
    t.datetime "contacted_at"
    t.datetime "converted_at"
    t.uuid "converted_patient_id"
    t.datetime "created_at", null: false
    t.string "first_name"
    t.boolean "is_general", default: false, null: false
    t.text "question"
    t.string "routed_to_role", default: "admissions", null: false
    t.string "source_prompt", default: "capture", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "zip"
    t.index ["agency_id", "status"], name: "index_inquiries_on_agency_id_and_status"
    t.index ["agency_id"], name: "index_inquiries_on_agency_id"
    t.index ["claimed_by_id"], name: "index_inquiries_on_claimed_by_id"
    t.index ["converted_patient_id"], name: "index_inquiries_on_converted_patient_id"
    t.index ["status", "created_at"], name: "index_inquiries_on_status_and_created_at"
  end

  create_table "medication_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "administered_at", null: false
    t.uuid "administered_by_id", null: false
    t.uuid "agency_id", null: false
    t.datetime "created_at", null: false
    t.string "dose_given", null: false
    t.boolean "effective"
    t.uuid "medication_order_id", null: false
    t.text "side_effects"
    t.integer "source", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["administered_by_id"], name: "index_medication_logs_on_administered_by_id"
    t.index ["agency_id", "administered_at"], name: "index_medication_logs_on_agency_id_and_administered_at"
    t.index ["agency_id"], name: "index_medication_logs_on_agency_id"
    t.index ["medication_order_id"], name: "index_medication_logs_on_medication_order_id"
  end

  create_table "medication_orders", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.datetime "created_at", null: false
    t.string "dose", null: false
    t.string "drug_name", null: false
    t.date "end_date"
    t.string "frequency", null: false
    t.uuid "patient_id", null: false
    t.uuid "prescribed_by_id", null: false
    t.boolean "prn", default: false, null: false
    t.string "prn_indication"
    t.integer "route", null: false
    t.date "start_date", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["agency_id", "patient_id", "status"], name: "index_medication_orders_on_agency_id_and_patient_id_and_status"
    t.index ["agency_id"], name: "index_medication_orders_on_agency_id"
    t.index ["patient_id"], name: "index_medication_orders_on_patient_id"
    t.index ["prescribed_by_id"], name: "index_medication_orders_on_prescribed_by_id"
  end

  create_table "notes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.string "author_role", null: false
    t.uuid "author_user_id"
    t.text "body", null: false
    t.boolean "clinician_only", default: false, null: false
    t.datetime "created_at", null: false
    t.uuid "patient_id", null: false
    t.datetime "read_at"
    t.integer "source", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "urgency", default: 0, null: false
    t.index ["agency_id", "patient_id", "created_at"], name: "idx_notes_on_agency_patient_time"
    t.index ["agency_id", "urgency", "read_at"], name: "idx_notes_on_agency_urgency_unread"
    t.index ["agency_id"], name: "index_notes_on_agency_id"
    t.index ["author_user_id"], name: "index_notes_on_author_user_id"
    t.index ["clinician_only"], name: "index_notes_on_clinician_only"
    t.index ["patient_id"], name: "index_notes_on_patient_id"
  end

  create_table "notifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.text "body"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.string "kind", null: false
    t.uuid "linked_id"
    t.string "linked_type"
    t.datetime "read_at"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["agency_id", "user_id", "read_at"], name: "idx_notifications_inbox"
    t.index ["agency_id"], name: "index_notifications_on_agency_id"
    t.index ["linked_type", "linked_id"], name: "index_notifications_on_linked_type_and_linked_id"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "patients", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "address_line1"
    t.string "address_line2"
    t.boolean "advance_directive_on_file", default: false, null: false
    t.uuid "agency_id", null: false
    t.jsonb "allergies", default: [], null: false
    t.uuid "assigned_chaplain_id"
    t.uuid "assigned_md_id"
    t.uuid "assigned_rn_id"
    t.uuid "assigned_sw_id"
    t.integer "benefit_period"
    t.uuid "branch_id"
    t.string "caregiver_name"
    t.string "caregiver_phone"
    t.date "cert_period_end"
    t.date "cert_period_start"
    t.string "city"
    t.integer "code_status", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "dob", null: false
    t.string "email"
    t.string "first_name", null: false
    t.string "gender"
    t.date "hospice_election_date"
    t.string "last_name", null: false
    t.string "mrn", null: false
    t.string "phone"
    t.boolean "polst_on_file", default: false, null: false
    t.string "preferred_language", default: "en", null: false
    t.string "primary_diagnosis"
    t.text "secondary_diagnoses"
    t.string "state"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "zip"
    t.index ["agency_id", "code_status"], name: "index_patients_on_agency_id_and_code_status"
    t.index ["agency_id", "mrn"], name: "idx_patients_on_agency_mrn", unique: true
    t.index ["agency_id", "status"], name: "index_patients_on_agency_id_and_status"
    t.index ["agency_id"], name: "index_patients_on_agency_id"
    t.index ["assigned_chaplain_id"], name: "index_patients_on_assigned_chaplain_id"
    t.index ["assigned_md_id"], name: "index_patients_on_assigned_md_id"
    t.index ["assigned_rn_id"], name: "index_patients_on_assigned_rn_id"
    t.index ["assigned_sw_id"], name: "index_patients_on_assigned_sw_id"
    t.index ["branch_id"], name: "index_patients_on_branch_id"
  end

  create_table "pharmacy_deliveries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.uuid "confirmed_by_id"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.integer "kind", null: false
    t.uuid "medication_order_id"
    t.uuid "patient_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["agency_id", "patient_id", "status"], name: "idx_on_agency_id_patient_id_status_f9bd6cc002"
    t.index ["agency_id"], name: "index_pharmacy_deliveries_on_agency_id"
    t.index ["confirmed_by_id"], name: "index_pharmacy_deliveries_on_confirmed_by_id"
    t.index ["medication_order_id"], name: "index_pharmacy_deliveries_on_medication_order_id"
    t.index ["patient_id"], name: "index_pharmacy_deliveries_on_patient_id"
  end

  create_table "pre_admit_evals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.datetime "certified_at"
    t.uuid "certified_by_id"
    t.datetime "created_at", null: false
    t.datetime "evaluated_at"
    t.uuid "evaluator_id"
    t.string "evaluator_license"
    t.string "evaluator_name"
    t.string "evaluator_role"
    t.datetime "finalized_at"
    t.boolean "lcd_criteria_supported", default: false, null: false
    t.datetime "noe_deadline_at"
    t.datetime "noe_filed_at"
    t.uuid "patient_id", null: false
    t.string "primary_icd10"
    t.string "primary_icd10_description"
    t.jsonb "raw_json", default: {}, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.uuid "visit_id"
    t.index ["agency_id"], name: "index_pre_admit_evals_on_agency_id"
    t.index ["certified_by_id"], name: "index_pre_admit_evals_on_certified_by_id"
    t.index ["evaluator_id"], name: "index_pre_admit_evals_on_evaluator_id"
    t.index ["noe_deadline_at"], name: "index_pre_admit_evals_on_noe_deadline_at"
    t.index ["patient_id"], name: "index_pre_admit_evals_on_patient_id"
    t.index ["raw_json"], name: "index_pre_admit_evals_on_raw_json", using: :gin
    t.index ["status"], name: "index_pre_admit_evals_on_status"
    t.index ["visit_id"], name: "index_pre_admit_evals_on_visit_id"
  end

  create_table "roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "label", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_roles_on_name", unique: true
  end

  create_table "user_roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.datetime "created_at", null: false
    t.uuid "role_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["agency_id"], name: "index_user_roles_on_agency_id"
    t.index ["role_id"], name: "index_user_roles_on_role_id"
    t.index ["user_id", "role_id", "agency_id"], name: "idx_user_roles_on_user_role_agency", unique: true
    t.index ["user_id"], name: "index_user_roles_on_user_id"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.uuid "agency_id"
    t.uuid "branch_id"
    t.datetime "created_at", null: false
    t.string "email", default: "", null: false
    t.integer "employment_type", default: 0, null: false
    t.string "encrypted_password", default: "", null: false
    t.boolean "family_access", default: false, null: false
    t.string "full_name", null: false
    t.date "license_expires_on"
    t.string "license_number"
    t.integer "max_caseload", default: 15, null: false
    t.string "npi", limit: 10
    t.boolean "on_call", default: false, null: false
    t.uuid "patient_id"
    t.string "phone_number"
    t.string "relationship"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.jsonb "service_zips", default: [], null: false
    t.string "timezone", default: "America/New_York", null: false
    t.datetime "updated_at", null: false
    t.index ["agency_id"], name: "index_users_on_agency_id"
    t.index ["branch_id"], name: "index_users_on_branch_id"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["license_expires_on"], name: "index_users_on_license_expires_on"
    t.index ["on_call"], name: "index_users_on_on_call"
    t.index ["patient_id"], name: "index_users_on_patient_id"
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["service_zips"], name: "index_users_on_service_zips", using: :gin
  end

  create_table "versions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at"
    t.string "event", null: false
    t.string "item_id", null: false
    t.string "item_type", null: false
    t.text "object"
    t.text "object_changes"
    t.string "whodunnit"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
  end

  create_table "visits", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.boolean "agent_authored", default: false, null: false
    t.boolean "billable", default: true, null: false
    t.datetime "created_at", null: false
    t.integer "discipline", null: false
    t.datetime "ended_at"
    t.string "facility_name"
    t.text "narrative"
    t.integer "pain_score"
    t.uuid "patient_id", null: false
    t.datetime "scheduled_at"
    t.integer "service_location", default: 0, null: false
    t.datetime "started_at"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.string "visit_code"
    t.integer "visit_type", default: 0, null: false
    t.jsonb "vitals", default: {}, null: false
    t.index ["agency_id", "agent_authored"], name: "index_visits_on_agency_id_and_agent_authored"
    t.index ["agency_id", "patient_id", "started_at"], name: "idx_visits_on_agency_patient_start"
    t.index ["agency_id", "visit_type"], name: "idx_visits_on_agency_visit_type"
    t.index ["agency_id"], name: "index_visits_on_agency_id"
    t.index ["patient_id"], name: "index_visits_on_patient_id"
    t.index ["service_location"], name: "index_visits_on_service_location"
    t.index ["user_id"], name: "index_visits_on_user_id"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_events", "agencies"
  add_foreign_key "branches", "agencies"
  add_foreign_key "branches", "users", column: "clinical_supervisor_id"
  add_foreign_key "branches", "users", column: "director_of_nursing_id"
  add_foreign_key "branches", "users", column: "manager_id"
  add_foreign_key "branches", "users", column: "medical_director_id"
  add_foreign_key "dme_orders", "agencies"
  add_foreign_key "dme_orders", "patients"
  add_foreign_key "inquiries", "agencies"
  add_foreign_key "inquiries", "patients", column: "converted_patient_id"
  add_foreign_key "inquiries", "users", column: "claimed_by_id"
  add_foreign_key "medication_logs", "agencies"
  add_foreign_key "medication_logs", "medication_orders"
  add_foreign_key "medication_logs", "users", column: "administered_by_id"
  add_foreign_key "medication_orders", "agencies"
  add_foreign_key "medication_orders", "patients"
  add_foreign_key "medication_orders", "users", column: "prescribed_by_id"
  add_foreign_key "notes", "agencies"
  add_foreign_key "notes", "patients"
  add_foreign_key "notes", "users", column: "author_user_id"
  add_foreign_key "notifications", "agencies"
  add_foreign_key "notifications", "users"
  add_foreign_key "patients", "agencies"
  add_foreign_key "patients", "branches"
  add_foreign_key "patients", "users", column: "assigned_chaplain_id"
  add_foreign_key "patients", "users", column: "assigned_md_id"
  add_foreign_key "patients", "users", column: "assigned_rn_id"
  add_foreign_key "patients", "users", column: "assigned_sw_id"
  add_foreign_key "pharmacy_deliveries", "agencies"
  add_foreign_key "pharmacy_deliveries", "medication_orders"
  add_foreign_key "pharmacy_deliveries", "patients"
  add_foreign_key "pharmacy_deliveries", "users", column: "confirmed_by_id"
  add_foreign_key "pre_admit_evals", "agencies"
  add_foreign_key "pre_admit_evals", "patients"
  add_foreign_key "pre_admit_evals", "users", column: "certified_by_id"
  add_foreign_key "pre_admit_evals", "users", column: "evaluator_id"
  add_foreign_key "pre_admit_evals", "visits"
  add_foreign_key "user_roles", "agencies"
  add_foreign_key "user_roles", "roles"
  add_foreign_key "user_roles", "users"
  add_foreign_key "users", "agencies"
  add_foreign_key "users", "branches"
  add_foreign_key "users", "patients"
  add_foreign_key "visits", "agencies"
  add_foreign_key "visits", "patients"
  add_foreign_key "visits", "users"
end
