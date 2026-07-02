require "test_helper"

# The NOE 5-day billing clock: within 48h nudges Insurance; overdue escalates
# to the DON + admin; idempotent across sweeps.
class NoeDeadlineSweepJobTest < ActiveSupport::TestCase
  setup do
    @agency  = create_agency
    @kendra  = create_user(agency: @agency, full_name: "Kendra Insurance", roles: %w[insurance])
    @don     = create_user(agency: @agency, full_name: "Dana DON",   roles: %w[don])
    @admin   = create_user(agency: @agency, full_name: "Alex Admin",  roles: %w[admin])
    @patient = create_patient(agency: @agency)
  end

  # Create a certified eval, then set an exact deadline (update_column bypasses
  # the stamp/freeze callback so the tier is deterministic).
  def certified_eval(deadline:)
    in_tenant(@agency) do
      e = PreAdmitEval.create!(agency: @agency, patient: @patient, evaluator: @don,
        evaluator_name: "Reggie RN", evaluated_at: Time.current, status: :certified,
        raw_json: { "pre_admit_eval" => {} })
      e.update_column(:noe_deadline_at, deadline)
      e
    end
  end

  def count(user, kind)
    in_tenant(@agency) { Notification.where(user: user, kind: kind).count }
  end

  test "nudges the Insurance coordinator when the NOE is within 48 hours" do
    certified_eval(deadline: 1.5.days.from_now)
    NoeDeadlineSweepJob.perform_now
    assert_equal 1, count(@kendra, NoeDeadlineSweepJob::KIND_IMMINENT)
    assert_equal 0, count(@don,    NoeDeadlineSweepJob::KIND_OVERDUE)
  end

  test "escalates to the DON and admin when the NOE is overdue" do
    certified_eval(deadline: 1.hour.ago)
    NoeDeadlineSweepJob.perform_now
    assert_equal 1, count(@don,   NoeDeadlineSweepJob::KIND_OVERDUE)
    assert_equal 1, count(@admin, NoeDeadlineSweepJob::KIND_OVERDUE)
    assert_equal 0, count(@kendra, NoeDeadlineSweepJob::KIND_IMMINENT), "insurance isn't paged for overdue"
  end

  test "is idempotent — repeated sweeps do not re-alert" do
    certified_eval(deadline: 1.hour.ago)
    NoeDeadlineSweepJob.perform_now
    assert_no_difference -> { in_tenant(@agency) { Notification.where(kind: NoeDeadlineSweepJob::KIND_OVERDUE).count } } do
      NoeDeadlineSweepJob.perform_now
    end
  end

  test "overdue re-alerts on a new calendar day until filed" do
    certified_eval(deadline: 1.hour.ago)
    NoeDeadlineSweepJob.perform_now
    # Age today's escalations into yesterday, then sweep again.
    in_tenant(@agency) { Notification.where(kind: NoeDeadlineSweepJob::KIND_OVERDUE).update_all(created_at: 1.day.ago) }
    assert_difference -> { in_tenant(@agency) { Notification.where(kind: NoeDeadlineSweepJob::KIND_OVERDUE).count } }, 2 do
      NoeDeadlineSweepJob.perform_now
    end
  end

  test "imminent stays once-and-done even across days" do
    certified_eval(deadline: 1.5.days.from_now)
    NoeDeadlineSweepJob.perform_now
    in_tenant(@agency) { Notification.where(kind: NoeDeadlineSweepJob::KIND_IMMINENT).update_all(created_at: 1.day.ago) }
    assert_no_difference -> { in_tenant(@agency) { Notification.where(kind: NoeDeadlineSweepJob::KIND_IMMINENT).count } } do
      NoeDeadlineSweepJob.perform_now
    end
  end

  test "leaves a healthy eval and an already-filed eval alone" do
    certified_eval(deadline: 10.days.from_now)                       # comfortably ahead
    filed = certified_eval(deadline: 1.hour.ago)                     # overdue but...
    in_tenant(@agency) { filed.update_column(:status, PreAdmitEval.statuses[:noe_filed]) }  # ...already filed

    NoeDeadlineSweepJob.perform_now
    total = in_tenant(@agency) do
      Notification.where(kind: [ NoeDeadlineSweepJob::KIND_IMMINENT, NoeDeadlineSweepJob::KIND_OVERDUE ]).count
    end
    assert_equal 0, total
  end
end
