class Visit < ApplicationRecord
  acts_as_tenant :agency
  has_paper_trail
  include AgentAuditable
  include BroadcastsPatientContext

  encrypts :narrative

  # Optional bedside audio capture — raw recording of the visit for the
  # chart (patient breath sounds, family voice, exact phrasing of goals
  # of care). Distinct from the narrative text field which is the
  # clinician's structured documentation. Played back by anyone with
  # chart access.
  has_one_attached :audio_note

  enum :discipline, {
    rn: 0, md: 1, sw: 2, chaplain: 3, aide: 4, don: 5
  }, prefix: true, validate: true

  enum :visit_type, {
    routine: 0, admission: 1, recert: 2, face_to_face: 3, discharge: 4, death: 5,
    follow_up: 6, inquiry: 7
  }, prefix: true, validate: true

  # Friendly category mapping the chart UI uses to gate the
  # Medicaid pre-eval pane and to label visit-type pickers. The
  # enum keeps every billable hospice variant Medicare cares
  # about; this layer collapses them into the buckets the RN
  # thinks about: initial / routine / follow_up / inquiry.
  VISIT_TYPE_CATEGORIES = {
    "admission"    => :initial,
    "routine"      => :routine,
    "recert"       => :routine,
    "face_to_face" => :follow_up,
    "follow_up"    => :follow_up,
    "discharge"    => :follow_up,
    "death"        => :follow_up,
    "inquiry"      => :inquiry
  }.freeze

  VISIT_TYPE_LABELS = {
    "admission"    => "Initial (new admission)",
    "routine"      => "Routine",
    "follow_up"    => "Follow-up",
    "inquiry"      => "Inquiry",
    "recert"       => "Recert (face-to-face)",
    "face_to_face" => "Face-to-face",
    "discharge"    => "Discharge",
    "death"        => "Death"
  }.freeze

  def visit_category   = VISIT_TYPE_CATEGORIES[visit_type.to_s] || :follow_up
  def needs_pre_eval?  = visit_category == :initial
  def visit_type_label = VISIT_TYPE_LABELS[visit_type.to_s] || visit_type.to_s.tr("_", " ").titleize

  ACTIVE_VISIT_WINDOW = 8.hours

  def currently_in_progress?
    started_at.present? &&
      ended_at.blank? &&
      started_at <= Time.current &&
      started_at >= ACTIVE_VISIT_WINDOW.ago
  end

  def completed_visit?
    started_at.present? && ended_at.present? && ended_at <= Time.current
  end

  def stale_in_progress?
    started_at.present? && ended_at.blank? && started_at < ACTIVE_VISIT_WINDOW.ago
  end

  # HCPCS place-of-service codes for hospice (Q-codes). Drives billing AND the
  # Contact & Location block on the visit detail view.
  enum :service_location, {
    home:                 0, # Q5001: Patient's private residence
    ipu:                  1, # Q5006: Inpatient hospice facility (freestanding)
    hospital_gip:         2, # Q5005: Inpatient hospital (GIP or acute pain)
    snf:                  3, # Q5004: Skilled Nursing Facility
    alf:                  4, # Q5002: Assisted Living Facility
    nursing_facility:     5, # Q5003: Long-Term Care / non-skilled nursing home
    psychiatric_facility: 6, # Q5008: Inpatient psychiatric facility
    group_home:           7, # Q5009: Group home / community residential
    temporary_lodging:    8, # Q5009: Hotel, resort, homeless shelter
    other:                9  # Q5009: Place not otherwise specified
  }, prefix: true, validate: true

  # True when the visit is at the patient's home address (Q5001). Every other
  # location needs a facility_name on the visit itself.
  def uses_patient_home_address?
    service_location_home?
  end

  # Who the RN interviewed during the visit (captured in the record wizard).
  INTERVIEWEE_LABELS = { "patient" => "the patient", "family" => "the family",
                         "both" => "patient and family" }.freeze
  def interviewee_display
    INTERVIEWEE_LABELS[interviewee.to_s] || interviewee.presence
  end

  # Per-turn audio timing from Deepgram: [{ "speaker"=>, "start"=>, "end"=> }].
  # The recorder posts it as a JSON string in the multipart finalize PATCH, so
  # coerce strings into an array before the jsonb column stores them.
  def transcript_segments=(val)
    val = (JSON.parse(val) rescue []) if val.is_a?(String)
    super(val.is_a?(Array) ? val : [])
  end

  # True once we have at least one timed segment with a numeric start.
  def transcript_segments?
    Array(transcript_segments).any? { |s| s.is_a?(Hash) && s["start"].is_a?(Numeric) }
  end

  belongs_to :agency
  belongs_to :patient
  belongs_to :user  # clinician who visited
  belongs_to :created_by_user, class_name: "User", optional: true # whoever scheduled it (admin, admissions, RN one-tap, AI agent)

  # Email the assigned clinician right after a human schedules this visit,
  # so they don't have to wait for the 24h reminder to learn about it.
  # No-ops when there's no assignee, the assignee has no email, the visit
  # was AI-suggested, or the scheduler assigned it to themselves.
  def deliver_assignment_email!(scheduled_by: nil)
    return if user_id.blank? || agent_authored?
    return if scheduled_by && scheduled_by.id == user_id
    return if user&.email.blank?

    VisitReminderMailer.with(visit: self, scheduled_by: scheduled_by).assigned.deliver_later
  rescue => e
    Rails.logger.warn("[Visit#deliver_assignment_email!] #{e.class}: #{e.message}")
  end
  has_one :pre_admit_eval
  # has_one's dependent: :nullify only unlinks ONE row. A rare duplicate draft
  # eval for the same visit left a straggler that blocked deletion with a FK
  # violation, so unlink ALL linked evals defensively before destroy. Drafts
  # stay reclaimable by the patient's next admission visit (visit_id -> NULL).
  before_destroy { PreAdmitEval.where(visit_id: id).update_all(visit_id: nil) }

  # Polymorphic audit rows from Signatures::Apply. For non-admission
  # visits we stamp a `rn_visit_signoff` row when the RN signs the
  # note (admission visits route via the eval, so their signature
  # rows hang off PreAdmitEval instead).
  has_many :signatures, as: :signable, dependent: :destroy

  def signed_off_by_rn?
    signatures.where(verification_method: "rn_visit_signoff").exists?
  end

  # Single predicate the chart UI uses to lock inline edits. True
  # when the linked eval is MD-certified OR a non-admission visit's
  # note has been RN-signed off — both cases mean the medical
  # record is closed and corrections need a late-entry note.
  def chart_locked?
    pre_admit_eval&.status_certified? || signed_off_by_rn?
  end

  validates :pain_score, inclusion: { in: 0..10, allow_nil: true }
  validate  :ended_after_started
  validate  :no_overlap_with_clinicians_other_visits

  # Live-update the assigned clinician's Today's Visits card when
  # the visit transitions (started_at / ended_at flips). Refresh on
  # create too so a brand-new scheduled visit shows up without page
  # reload for the assignee.
  after_commit :broadcast_dashboard_visit_change, on: %i[create update],
               if: :affects_dashboard?

  def affects_dashboard?
    return true if previous_changes.key?("started_at") || previous_changes.key?("ended_at")
    return true if previous_changes.key?("scheduled_at") || previous_changes.key?("user_id")
    false
  end

  def broadcast_dashboard_visit_change
    return unless user
    data = DashboardData.for(user)
    Turbo::StreamsChannel.broadcast_replace_to(
      "dashboard:user:#{user.id}",
      target:  "dashboard-todays-visits-#{user.id}",
      partial: "dashboards/todays_visits_card",
      locals:  { todays_visits: data.todays_visits, viewer_user_id: user.id }
    )
    DashboardData.broadcast_needs_action(user)
  rescue => e
    Rails.logger.warn("[Visit#broadcast_dashboard_visit_change] #{e.class}: #{e.message}")
  end

  # Minutes of drive time we assume before AND after any visit.
  # Hospice nursing is mobile; this is the windshield buffer rule.
  WINDSHIELD_BUFFER_MINUTES = 30

  # Default visit duration we assume when ended_at is nil (still scheduled,
  # not yet completed). Used only for the overlap check.
  DEFAULT_DURATION_MINUTES = 60

  # ── Time helpers ────────────────────────────────────────────────────

  # Real start used by the overlap check. Prefer scheduled_at; fall back
  # to started_at only if scheduled_at is missing.
  def anchor_start
    scheduled_at || started_at
  end

  # Real end used by the overlap check. If ended_at is set, use it.
  # Otherwise assume DEFAULT_DURATION_MINUTES past anchor_start.
  def anchor_end
    return ended_at if ended_at
    return nil     unless anchor_start
    anchor_start + DEFAULT_DURATION_MINUTES.minutes
  end

  # Buffered window for the windshield rule. The clinician's calendar is
  # considered occupied from (start - 30 min) to (end + 30 min).
  def buffered_start
    anchor_start && (anchor_start - WINDSHIELD_BUFFER_MINUTES.minutes)
  end

  def buffered_end
    anchor_end && (anchor_end + WINDSHIELD_BUFFER_MINUTES.minutes)
  end

  # ── Huddle helper (Rule 3) ──────────────────────────────────────────
  # Returns a hash of discipline => count for visits on the same patient
  # on the same calendar date as the given anchor time. Read by the
  # AgentBrain context so an agent can avoid piling on a family.
  def self.disciplines_scheduled_for(patient_id:, on_date:, exclude_id: nil)
    day_start = on_date.beginning_of_day
    day_end   = on_date.end_of_day
    scope = where(patient_id: patient_id)
              .where("COALESCE(scheduled_at, started_at) BETWEEN ? AND ?", day_start, day_end)
    scope = scope.where.not(id: exclude_id) if exclude_id
    scope.group(:discipline).count
         .transform_keys { |v| disciplines.key(v) || v.to_s }
  end

  # ──────────────────────────────────────────────────────────────────
  private

  def ended_after_started
    return unless started_at && ended_at
    errors.add(:ended_at, "must be after started_at") if ended_at < started_at
  end

  # Rule 1 + Rule 2 together: a clinician cannot be scheduled into a window
  # that overlaps another of their own visits, including a 30-minute drive
  # buffer on each side of both visits.
  #
  # Two visits A and B conflict if:
  #   A.buffered_start < B.buffered_end  AND  A.buffered_end > B.buffered_start
  def no_overlap_with_clinicians_other_visits
    return unless user_id && anchor_start
    my_start = buffered_start
    my_end   = buffered_end
    return unless my_start && my_end

    conflict = self.class.unscoped
                   .where(user_id: user_id)
                   .where.not(id: id)
                   .where(
                     # Overlap with buffered window of the candidate OTHER visit.
                     # other.scheduled_at - 30min < my_end  AND  other_end + 30min > my_start
                     "(COALESCE(scheduled_at, started_at) - make_interval(mins => ?)) < ? " \
                     "AND (COALESCE(ended_at, COALESCE(scheduled_at, started_at) + make_interval(mins => ?)) + make_interval(mins => ?)) > ?",
                     WINDSHIELD_BUFFER_MINUTES, my_end,
                     DEFAULT_DURATION_MINUTES,
                     WINDSHIELD_BUFFER_MINUTES, my_start
                   )
                   .first

    return unless conflict

    errors.add(
      :scheduled_at,
      "overlaps with an existing visit for this clinician " \
      "(visit #{conflict.id} at #{conflict.anchor_start&.strftime('%Y-%m-%d %H:%M')}). " \
      "Windshield buffer of #{WINDSHIELD_BUFFER_MINUTES} minutes is enforced on both sides."
    )
  end
end
