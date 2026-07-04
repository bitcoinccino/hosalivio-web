module Admin
  # Agency-wide oversight answers for the manager/admin assistant — the signals
  # the Mission Stage dashboard surfaces, flattened into scannable Item lists.
  # Read-only and agency-scoped: nothing here is ever written to a patient chart.
  # Every command returns [Item] so the assistant view renders them uniformly.
  class Overview
    Item = Struct.new(:text, :urgent, :patient_id, keyword_init: true)

    # command method => answer title.
    COMMANDS = {
      "pending_items"              => "Today's priority items",
      "patients_needing_attention" => "Patients needing attention",
      "compliance_status"          => "Compliance status",
      "new_referrals"              => "New referrals",
      "daily_report"               => "Daily report"
    }.freeze

    def self.run(command, agency)
      new(agency).public_send(command)
    end

    def initialize(agency)
      @agency = agency
    end

    def pending_items
      with_tenant do
        finals = pending_evals.select(&:status_final?)
        certs  = pending_evals.select(&:status_certified?)
        items  = []

        items << Item.new(text: "#{finals.size} pre-admit eval#{plural(finals.size)} awaiting MD certification", urgent: false) if finals.any?
        certs.select(&:noe_overdue?).each do |e|
          items << Item.new(text: "NOE overdue — #{e.patient&.full_name}", urgent: true, patient_id: e.patient_id)
        end
        certs.select { |e| noe_due_soon?(e) }.each do |e|
          items << Item.new(text: "NOE due #{noe_when(e)} — #{e.patient&.full_name}", urgent: false, patient_id: e.patient_id)
        end
        (finals + certs).each do |e|
          missing = e.missing_required_documents
          items << Item.new(text: "#{e.patient&.full_name}: missing #{missing.to_sentence}", urgent: false, patient_id: e.patient_id) if missing.present?
        end
        items
      end
    end

    # Patient-centric: one row per patient with what's holding them up.
    def patients_needing_attention
      with_tenant do
        by_patient = {}
        pending_evals.each do |e|
          reasons = []
          reasons << "awaiting MD certification" if e.status_final?
          reasons << "NOE overdue"               if e.noe_overdue?
          reasons << "missing #{e.missing_required_documents.to_sentence}" if e.missing_required_documents.present?
          next if reasons.empty?
          (by_patient[e.patient_id] ||= { patient: e.patient, reasons: [] })[:reasons].concat(reasons)
        end
        by_patient.map do |pid, h|
          Item.new(text: "#{h[:patient]&.full_name} — #{h[:reasons].uniq.to_sentence}",
                   urgent: h[:reasons].any? { |r| r.include?("overdue") }, patient_id: pid)
        end
      end
    end

    def compliance_status
      with_tenant do
        blockers = pending_evals.count { |e| e.certification_blockers.present? }
        certs    = pending_evals.select(&:status_certified?)
        overdue  = certs.count(&:noe_overdue?)
        soon     = certs.count { |e| noe_due_soon?(e) }
        no_directive = pending_evals.count { |e| e.missing_required_documents.any? { |d| d.match?(/polst|dnr|advance/i) } }
        [
          Item.new(text: "#{blockers} eval#{plural(blockers)} with open certification blockers", urgent: blockers.positive?),
          Item.new(text: "#{overdue} NOE overdue · #{soon} due today/tomorrow", urgent: overdue.positive?),
          Item.new(text: "#{no_directive} patient#{plural(no_directive)} missing a POLST / advance directive / DNR", urgent: false)
        ]
      end
    end

    def new_referrals
      with_tenant do
        Inquiry.where(agency: @agency, status: [ :new_lead, :claimed, :contacted ])
               .order(created_at: :desc).limit(10).map do |i|
          Item.new(text: "#{i.display_label} — #{i.status.to_s.tr('_', ' ')} · #{i.created_at.strftime('%b %-d')}",
                   urgent: i.status_new_lead?)
        end
      end
    end

    def daily_report
      with_tenant do
        start = Time.current.beginning_of_day
        referrals_today  = Inquiry.where(agency: @agency).where(created_at: start..).count
        registered_today = Patient.where(agency: @agency).where(created_at: start..).count
        open_items       = pending_items.size
        [
          Item.new(text: "#{referrals_today} new referral#{plural(referrals_today)} today", urgent: false),
          Item.new(text: "#{registered_today} new patient registration#{plural(registered_today)} today", urgent: false),
          Item.new(text: "#{open_items} open priority item#{plural(open_items)}", urgent: open_items.positive?)
        ]
      end
    end

    private

    def pending_evals
      @pending_evals ||= PreAdmitEval.where(agency: @agency, status: [ :final, :certified ]).includes(:patient).to_a
    end

    def with_tenant(&block)
      ActsAsTenant.with_tenant(@agency, &block)
    end

    def plural(count)
      count == 1 ? "" : "s"
    end

    def noe_due_soon?(eval_rec)
      eval_rec.noe_deadline_at && !eval_rec.noe_overdue? && eval_rec.noe_deadline_at.to_date <= Date.current + 1.day
    end

    def noe_when(eval_rec)
      eval_rec.noe_deadline_at.to_date <= Date.current ? "today" : "tomorrow"
    end
  end
end
