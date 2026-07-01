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

ActiveRecord::Schema[8.1].define(version: 2026_07_01_140000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "citext"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

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
    t.integer "accreditation_body"
    t.boolean "active", default: true, null: false
    t.string "address_line1"
    t.string "address_line2"
    t.string "administrator_name"
    t.string "after_hours_instructions"
    t.jsonb "agent_overrides", default: {}, null: false
    t.jsonb "agent_personas", default: {}, null: false
    t.integer "billing_tier", default: 0, null: false
    t.text "bio"
    t.string "city"
    t.datetime "created_at", null: false
    t.string "dba_name"
    t.integer "dme_partner"
    t.string "emoji", default: "🩺", null: false
    t.integer "emr_system"
    t.jsonb "features", default: {}, null: false
    t.string "hero_color", default: "#D97757", null: false
    t.jsonb "insurance_accepted", default: [], null: false
    t.boolean "is_partner", default: false, null: false
    t.jsonb "languages", default: ["en"], null: false
    t.integer "mac_region"
    t.string "medicare_provider_number"
    t.string "name", null: false
    t.string "npi"
    t.integer "pharmacy_partner"
    t.string "phone"
    t.jsonb "pricing_tiers", default: {}, null: false
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
    t.datetime "acknowledged_at"
    t.uuid "acknowledged_by_user_id"
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
    t.index ["acknowledged_at"], name: "index_agent_events_on_acknowledged_at", where: "(acknowledged_at IS NOT NULL)"
    t.index ["acknowledged_by_user_id"], name: "index_agent_events_on_acknowledged_by_user_id"
    t.index ["agency_id", "agent_id", "happened_at"], name: "idx_agent_events_on_agency_agent_time"
    t.index ["agency_id", "happened_at"], name: "index_agent_events_on_agency_id_and_happened_at"
    t.index ["agency_id"], name: "index_agent_events_on_agency_id"
    t.index ["subject_type", "subject_id"], name: "index_agent_events_on_subject"
  end

  create_table "branches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "address_line1"
    t.string "address_line2"
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
    t.index ["ccn"], name: "index_branches_on_ccn"
    t.index ["clinical_supervisor_id"], name: "index_branches_on_clinical_supervisor_id"
    t.index ["director_of_nursing_id"], name: "index_branches_on_director_of_nursing_id"
    t.index ["manager_id"], name: "index_branches_on_manager_id"
    t.index ["medical_director_id"], name: "index_branches_on_medical_director_id"
    t.index ["npi"], name: "index_branches_on_npi"
    t.index ["service_area_counties"], name: "index_branches_on_service_area_counties", using: :gin
    t.index ["service_area_zips"], name: "index_branches_on_service_area_zips", using: :gin
  end

  create_table "cc_controlled_substance_counts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.uuid "cc_interval_chart_id", null: false
    t.integer "count_at_end"
    t.integer "count_at_start"
    t.datetime "created_at", null: false
    t.string "drug_name", null: false
    t.uuid "medication_order_id"
    t.datetime "updated_at", null: false
    t.index ["agency_id"], name: "index_cc_controlled_substance_counts_on_agency_id"
    t.index ["cc_interval_chart_id"], name: "index_cc_controlled_substance_counts_on_cc_interval_chart_id"
    t.index ["medication_order_id"], name: "index_cc_controlled_substance_counts_on_medication_order_id"
  end

  create_table "cc_interval_charts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.boolean "airborne_isolation", default: false, null: false
    t.boolean "contact_isolation", default: false, null: false
    t.datetime "created_at", null: false
    t.date "date_of_shift", null: false
    t.boolean "droplet_isolation", default: false, null: false
    t.boolean "face_shield_or_goggles", default: false, null: false
    t.boolean "facility_or_ha_shift", default: false, null: false
    t.boolean "gown_or_apron", default: false, null: false
    t.boolean "mask", default: false, null: false
    t.boolean "n95_mask", default: false, null: false
    t.uuid "patient_id", null: false
    t.boolean "see_attached_addendum", default: false, null: false
    t.time "shift_end_time"
    t.time "shift_start_time"
    t.integer "status", default: 0, null: false
    t.boolean "universal_precautions", default: false, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.uuid "visit_id"
    t.index ["agency_id"], name: "index_cc_interval_charts_on_agency_id"
    t.index ["patient_id"], name: "index_cc_interval_charts_on_patient_id"
    t.index ["user_id"], name: "index_cc_interval_charts_on_user_id"
    t.index ["visit_id"], name: "index_cc_interval_charts_on_visit_id"
  end

  create_table "cc_poc_interventions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.uuid "cc_interval_chart_id", null: false
    t.datetime "created_at", null: false
    t.string "initial_level"
    t.time "initial_time"
    t.string "med_name_and_dose"
    t.integer "med_source", default: 0, null: false
    t.uuid "medication_order_id"
    t.jsonb "non_verbal_indicators", default: {}, null: false
    t.string "post_level"
    t.time "post_time"
    t.string "ref_number"
    t.text "response_to_care"
    t.string "symptom"
    t.datetime "updated_at", null: false
    t.index ["agency_id"], name: "index_cc_poc_interventions_on_agency_id"
    t.index ["cc_interval_chart_id"], name: "index_cc_poc_interventions_on_cc_interval_chart_id"
    t.index ["medication_order_id"], name: "index_cc_poc_interventions_on_medication_order_id"
  end

  create_table "cc_vitals_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.string "blood_pressure"
    t.string "bowel_movement"
    t.uuid "cc_interval_chart_id", null: false
    t.datetime "created_at", null: false
    t.string "intake_details"
    t.string "output_diapers"
    t.integer "pulse"
    t.time "recorded_at", null: false
    t.integer "respiration"
    t.decimal "temperature", precision: 4, scale: 1
    t.datetime "updated_at", null: false
    t.index ["agency_id"], name: "index_cc_vitals_records_on_agency_id"
    t.index ["cc_interval_chart_id"], name: "index_cc_vitals_records_on_cc_interval_chart_id"
  end

  create_table "chat_feedbacks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "answer", null: false
    t.string "audience"
    t.text "comment"
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.text "question", null: false
    t.string "rating", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.index ["created_at"], name: "index_chat_feedbacks_on_created_at"
    t.index ["rating"], name: "index_chat_feedbacks_on_rating"
  end

  create_table "consent_forms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.datetime "created_at", null: false
    t.string "document_hash"
    t.text "form_content"
    t.string "kind", null: false
    t.uuid "patient_id", null: false
    t.datetime "signed_at", null: false
    t.text "signer_authority"
    t.string "signer_name", null: false
    t.string "signer_relationship"
    t.string "signer_role", null: false
    t.datetime "updated_at", null: false
    t.uuid "witnessed_by_id", null: false
    t.index ["agency_id"], name: "index_consent_forms_on_agency_id"
    t.index ["patient_id", "kind"], name: "index_consent_forms_on_patient_id_and_kind"
    t.index ["patient_id"], name: "index_consent_forms_on_patient_id"
    t.index ["signed_at"], name: "index_consent_forms_on_signed_at"
    t.index ["witnessed_by_id"], name: "index_consent_forms_on_witnessed_by_id"
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

  create_table "emr_sync_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.datetime "created_at", null: false
    t.string "external_encounter_id"
    t.jsonb "payload_sent"
    t.uuid "pre_admit_eval_id", null: false
    t.jsonb "response_received"
    t.integer "retry_count", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.datetime "synchronized_at"
    t.string "target_system", default: "VITAS_PORTAL", null: false
    t.datetime "updated_at", null: false
    t.index ["agency_id"], name: "index_emr_sync_logs_on_agency_id"
    t.index ["pre_admit_eval_id", "target_system"], name: "idx_one_sync_log_per_eval_target", unique: true
    t.index ["pre_admit_eval_id"], name: "index_emr_sync_logs_on_pre_admit_eval_id"
  end

  create_table "eval_revision_requests", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "comment", null: false
    t.datetime "created_at", null: false
    t.string "document_hash"
    t.uuid "pre_admit_eval_id", null: false
    t.uuid "requester_id", null: false
    t.datetime "resolved_at"
    t.datetime "updated_at", null: false
    t.index ["pre_admit_eval_id"], name: "index_eval_revision_requests_on_pre_admit_eval_id"
    t.index ["requester_id"], name: "index_eval_revision_requests_on_requester_id"
  end

  create_table "icd10_codes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "billable", default: true, null: false
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.string "description", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_icd10_codes_on_code", unique: true
    t.index ["code"], name: "index_icd10_codes_on_code_pattern", opclass: :varchar_pattern_ops
    t.index ["description"], name: "index_icd10_codes_on_description_trgm", opclass: :gin_trgm_ops, using: :gin
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
    t.string "caregiver_phone"
    t.datetime "claimed_at"
    t.uuid "claimed_by_id"
    t.string "contact"
    t.datetime "contacted_at"
    t.datetime "converted_at"
    t.uuid "converted_patient_id"
    t.datetime "created_at", null: false
    t.datetime "desired_date"
    t.string "diagnosis"
    t.string "dob"
    t.string "email"
    t.string "external_mrn"
    t.string "external_referral_id"
    t.string "first_name"
    t.boolean "is_general", default: false, null: false
    t.string "last_name"
    t.text "question"
    t.text "raw_fhir_payload"
    t.text "reason_for_referral"
    t.datetime "referral_date"
    t.string "referring_provider"
    t.string "requested_service"
    t.string "requester_role"
    t.string "routed_to_role", default: "admissions", null: false
    t.string "source_prompt", default: "capture", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "urgency"
    t.string "zip"
    t.index ["agency_id", "external_referral_id"], name: "index_inquiries_on_agency_and_external_referral_id"
    t.index ["agency_id", "status"], name: "index_inquiries_on_agency_id_and_status"
    t.index ["agency_id"], name: "index_inquiries_on_agency_id"
    t.index ["claimed_by_id"], name: "index_inquiries_on_claimed_by_id"
    t.index ["converted_patient_id"], name: "index_inquiries_on_converted_patient_id"
    t.index ["status", "created_at"], name: "index_inquiries_on_status_and_created_at"
  end

  create_table "login_codes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "code_digest", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "ip"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["code_digest"], name: "index_login_codes_on_code_digest"
    t.index ["expires_at"], name: "index_login_codes_on_expires_at"
    t.index ["user_id"], name: "index_login_codes_on_user_id"
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
    t.boolean "comfort_kit", default: false, null: false
    t.boolean "controlled", default: false, null: false
    t.datetime "created_at", null: false
    t.string "dose", null: false
    t.string "drug_name", null: false
    t.date "end_date"
    t.string "frequency", null: false
    t.text "instructions"
    t.uuid "patient_id", null: false
    t.uuid "pre_admit_eval_id"
    t.uuid "prescribed_by_id", null: false
    t.boolean "prn", default: false, null: false
    t.string "prn_indication"
    t.string "quantity"
    t.integer "route", null: false
    t.date "start_date", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["agency_id", "patient_id", "status"], name: "index_medication_orders_on_agency_id_and_patient_id_and_status"
    t.index ["agency_id"], name: "index_medication_orders_on_agency_id"
    t.index ["patient_id", "comfort_kit"], name: "index_medication_orders_on_patient_id_and_comfort_kit"
    t.index ["patient_id"], name: "index_medication_orders_on_patient_id"
    t.index ["pre_admit_eval_id"], name: "index_medication_orders_on_pre_admit_eval_id"
    t.index ["prescribed_by_id"], name: "index_medication_orders_on_prescribed_by_id"
  end

  create_table "notes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.string "author_role", null: false
    t.uuid "author_user_id"
    t.text "body", null: false
    t.boolean "clinician_only", default: false, null: false
    t.datetime "created_at", null: false
    t.boolean "family_offer", default: false, null: false
    t.datetime "feedback_at"
    t.uuid "feedback_by_id"
    t.text "feedback_notes"
    t.jsonb "feedback_reasons", default: [], null: false
    t.integer "feedback_score"
    t.uuid "parent_note_id"
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
    t.index ["feedback_by_id"], name: "index_notes_on_feedback_by_id"
    t.index ["feedback_score"], name: "index_notes_on_feedback_score", where: "(feedback_score IS NOT NULL)"
    t.index ["parent_note_id", "created_at"], name: "index_notes_on_parent_note_id_and_created_at"
    t.index ["parent_note_id"], name: "index_notes_on_parent_note_id"
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

  create_table "outbound_pings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.jsonb "delivered_channels", default: [], null: false
    t.string "kind", null: false
    t.text "last_error"
    t.datetime "link_expires_at", null: false
    t.string "link_token", null: false
    t.jsonb "payload", default: {}, null: false
    t.string "preview", null: false
    t.bigint "telegram_message_id"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["agency_id"], name: "index_outbound_pings_on_agency_id"
    t.index ["consumed_at"], name: "index_outbound_pings_on_consumed_at", where: "(consumed_at IS NOT NULL)"
    t.index ["created_at"], name: "index_outbound_pings_on_created_at"
    t.index ["kind"], name: "index_outbound_pings_on_kind"
    t.index ["link_token"], name: "index_outbound_pings_on_link_token", unique: true
    t.index ["telegram_message_id"], name: "index_outbound_pings_on_telegram_message_id", where: "(telegram_message_id IS NOT NULL)"
    t.index ["user_id", "delivered_at"], name: "index_outbound_pings_on_user_id_and_delivered_at"
    t.index ["user_id"], name: "index_outbound_pings_on_user_id"
  end

  create_table "patient_documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "agency_id", null: false
    t.datetime "created_at", null: false
    t.string "kind"
    t.uuid "patient_id", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.uuid "uploaded_by_id"
    t.index ["agency_id"], name: "index_patient_documents_on_agency_id"
    t.index ["patient_id"], name: "index_patient_documents_on_patient_id"
    t.index ["uploaded_by_id"], name: "index_patient_documents_on_uploaded_by_id"
  end

  create_table "patients", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "address_line1"
    t.string "address_line2"
    t.boolean "advance_directive_on_file", default: false, null: false
    t.uuid "agency_id", null: false
    t.jsonb "allergies", default: [], null: false
    t.uuid "assigned_chaplain_id"
    t.uuid "assigned_lpn_id"
    t.uuid "assigned_md_id"
    t.uuid "assigned_rn_id"
    t.uuid "assigned_sw_id"
    t.uuid "assigned_visit_rn_id"
    t.integer "benefit_period"
    t.uuid "branch_id"
    t.string "caregiver_name"
    t.string "caregiver_phone"
    t.string "caregiver_relationship"
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
    t.boolean "interpreter_needed", default: false, null: false
    t.string "last_name", null: false
    t.string "mrn", null: false
    t.string "phone"
    t.boolean "polst_on_file", default: false, null: false
    t.string "preferred_language", default: "en", null: false
    t.string "preferred_name"
    t.string "primary_diagnosis"
    t.string "pronouns"
    t.string "religion"
    t.text "secondary_diagnoses"
    t.string "state"
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "veteran_branch"
    t.string "veteran_status"
    t.string "zip"
    t.index ["agency_id", "code_status"], name: "index_patients_on_agency_id_and_code_status"
    t.index ["agency_id", "mrn"], name: "idx_patients_on_agency_mrn", unique: true
    t.index ["agency_id", "status"], name: "index_patients_on_agency_id_and_status"
    t.index ["agency_id"], name: "index_patients_on_agency_id"
    t.index ["assigned_chaplain_id"], name: "index_patients_on_assigned_chaplain_id"
    t.index ["assigned_lpn_id"], name: "index_patients_on_assigned_lpn_id"
    t.index ["assigned_md_id"], name: "index_patients_on_assigned_md_id"
    t.index ["assigned_rn_id"], name: "index_patients_on_assigned_rn_id"
    t.index ["assigned_sw_id"], name: "index_patients_on_assigned_sw_id"
    t.index ["assigned_visit_rn_id"], name: "index_patients_on_assigned_visit_rn_id"
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
    t.integer "sync_status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.uuid "visit_id"
    t.index ["agency_id"], name: "index_pre_admit_evals_on_agency_id"
    t.index ["certified_by_id"], name: "index_pre_admit_evals_on_certified_by_id"
    t.index ["evaluator_id"], name: "index_pre_admit_evals_on_evaluator_id"
    t.index ["noe_deadline_at"], name: "index_pre_admit_evals_on_noe_deadline_at"
    t.index ["patient_id"], name: "index_pre_admit_evals_on_patient_id"
    t.index ["raw_json"], name: "index_pre_admit_evals_on_raw_json", using: :gin
    t.index ["status"], name: "index_pre_admit_evals_on_status"
    t.index ["visit_id"], name: "idx_one_pre_admit_eval_per_visit", unique: true, where: "(visit_id IS NOT NULL)"
    t.index ["visit_id"], name: "index_pre_admit_evals_on_visit_id"
  end

  create_table "roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "label", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_roles_on_name", unique: true
  end

  create_table "signatures", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "document_hash", null: false
    t.text "intent_text", null: false
    t.string "ip_address"
    t.uuid "signable_id", null: false
    t.string "signable_type", null: false
    t.uuid "signature_blob_id"
    t.datetime "signed_at", null: false
    t.string "signed_name"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.uuid "user_id", null: false
    t.string "verification_method", null: false
    t.index ["signable_type", "signable_id"], name: "index_signatures_on_signable_type_and_signable_id"
    t.index ["signed_at"], name: "index_signatures_on_signed_at"
    t.index ["user_id"], name: "index_signatures_on_user_id"
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
    t.string "friendly_name"
    t.string "full_name", null: false
    t.date "license_expires_on"
    t.string "license_number"
    t.integer "max_caseload", default: 15, null: false
    t.jsonb "notification_channels", default: {}, null: false
    t.string "npi", limit: 10
    t.boolean "on_call", default: false, null: false
    t.uuid "patient_id"
    t.string "phone_number"
    t.string "relationship"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.jsonb "service_zips", default: [], null: false
    t.datetime "signature_registered_at"
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
    t.uuid "created_by_user_id"
    t.integer "discipline", null: false
    t.datetime "ended_at"
    t.string "facility_name"
    t.string "interviewee"
    t.string "interviewee_label"
    t.text "narrative"
    t.text "narrative_raw"
    t.integer "pain_score"
    t.uuid "patient_id", null: false
    t.datetime "scheduled_at"
    t.integer "service_location", default: 0, null: false
    t.datetime "started_at"
    t.text "team_summary"
    t.jsonb "transcript_segments", default: [], null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.string "visit_code"
    t.integer "visit_type", default: 0, null: false
    t.jsonb "vitals", default: {}, null: false
    t.index ["agency_id", "agent_authored"], name: "index_visits_on_agency_id_and_agent_authored"
    t.index ["agency_id", "patient_id", "started_at"], name: "idx_visits_on_agency_patient_start"
    t.index ["agency_id", "visit_type"], name: "idx_visits_on_agency_visit_type"
    t.index ["agency_id"], name: "index_visits_on_agency_id"
    t.index ["created_by_user_id"], name: "index_visits_on_created_by_user_id"
    t.index ["patient_id"], name: "index_visits_on_patient_id"
    t.index ["service_location"], name: "index_visits_on_service_location"
    t.index ["user_id"], name: "index_visits_on_user_id"
  end

  create_table "zip_codes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "city"
    t.string "county"
    t.datetime "created_at", null: false
    t.string "state"
    t.datetime "updated_at", null: false
    t.string "zip", null: false
    t.index ["zip"], name: "index_zip_codes_on_zip", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_events", "agencies"
  add_foreign_key "agent_events", "users", column: "acknowledged_by_user_id"
  add_foreign_key "branches", "agencies"
  add_foreign_key "branches", "users", column: "clinical_supervisor_id"
  add_foreign_key "branches", "users", column: "director_of_nursing_id"
  add_foreign_key "branches", "users", column: "manager_id"
  add_foreign_key "branches", "users", column: "medical_director_id"
  add_foreign_key "cc_controlled_substance_counts", "agencies"
  add_foreign_key "cc_controlled_substance_counts", "cc_interval_charts"
  add_foreign_key "cc_controlled_substance_counts", "medication_orders"
  add_foreign_key "cc_interval_charts", "agencies"
  add_foreign_key "cc_interval_charts", "patients"
  add_foreign_key "cc_interval_charts", "users"
  add_foreign_key "cc_interval_charts", "visits"
  add_foreign_key "cc_poc_interventions", "agencies"
  add_foreign_key "cc_poc_interventions", "cc_interval_charts"
  add_foreign_key "cc_poc_interventions", "medication_orders"
  add_foreign_key "cc_vitals_records", "agencies"
  add_foreign_key "cc_vitals_records", "cc_interval_charts"
  add_foreign_key "consent_forms", "agencies"
  add_foreign_key "consent_forms", "patients"
  add_foreign_key "dme_orders", "agencies"
  add_foreign_key "dme_orders", "patients"
  add_foreign_key "emr_sync_logs", "agencies"
  add_foreign_key "emr_sync_logs", "pre_admit_evals"
  add_foreign_key "eval_revision_requests", "pre_admit_evals"
  add_foreign_key "inquiries", "agencies"
  add_foreign_key "inquiries", "patients", column: "converted_patient_id"
  add_foreign_key "inquiries", "users", column: "claimed_by_id"
  add_foreign_key "login_codes", "users"
  add_foreign_key "medication_logs", "agencies"
  add_foreign_key "medication_logs", "medication_orders"
  add_foreign_key "medication_logs", "users", column: "administered_by_id"
  add_foreign_key "medication_orders", "agencies"
  add_foreign_key "medication_orders", "patients"
  add_foreign_key "medication_orders", "pre_admit_evals", on_delete: :nullify
  add_foreign_key "medication_orders", "users", column: "prescribed_by_id"
  add_foreign_key "notes", "agencies"
  add_foreign_key "notes", "notes", column: "parent_note_id", on_delete: :nullify
  add_foreign_key "notes", "patients"
  add_foreign_key "notes", "users", column: "author_user_id"
  add_foreign_key "notes", "users", column: "feedback_by_id"
  add_foreign_key "notifications", "agencies"
  add_foreign_key "notifications", "users"
  add_foreign_key "outbound_pings", "agencies"
  add_foreign_key "outbound_pings", "users"
  add_foreign_key "patient_documents", "agencies"
  add_foreign_key "patient_documents", "patients"
  add_foreign_key "patient_documents", "users", column: "uploaded_by_id"
  add_foreign_key "patients", "agencies"
  add_foreign_key "patients", "branches"
  add_foreign_key "patients", "users", column: "assigned_chaplain_id"
  add_foreign_key "patients", "users", column: "assigned_lpn_id"
  add_foreign_key "patients", "users", column: "assigned_md_id"
  add_foreign_key "patients", "users", column: "assigned_rn_id"
  add_foreign_key "patients", "users", column: "assigned_sw_id"
  add_foreign_key "patients", "users", column: "assigned_visit_rn_id"
  add_foreign_key "pharmacy_deliveries", "agencies"
  add_foreign_key "pharmacy_deliveries", "medication_orders"
  add_foreign_key "pharmacy_deliveries", "patients"
  add_foreign_key "pharmacy_deliveries", "users", column: "confirmed_by_id"
  add_foreign_key "pre_admit_evals", "agencies"
  add_foreign_key "pre_admit_evals", "patients"
  add_foreign_key "pre_admit_evals", "users", column: "certified_by_id"
  add_foreign_key "pre_admit_evals", "users", column: "evaluator_id"
  add_foreign_key "pre_admit_evals", "visits"
  add_foreign_key "signatures", "users"
  add_foreign_key "user_roles", "agencies"
  add_foreign_key "user_roles", "roles"
  add_foreign_key "user_roles", "users"
  add_foreign_key "users", "agencies"
  add_foreign_key "users", "branches"
  add_foreign_key "users", "patients"
  add_foreign_key "visits", "agencies"
  add_foreign_key "visits", "patients"
  add_foreign_key "visits", "users"
  add_foreign_key "visits", "users", column: "created_by_user_id"
end
