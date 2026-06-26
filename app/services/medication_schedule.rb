# Tiny clinical scheduler — parses hospice frequency strings, computes "next due".
# Not a full FHIR Timing implementation; handles the formats we actually use.
#
# Accepts: "q4h prn", "q6h", "BID", "TID", "QID", "daily", "qhs", "once daily"
# Returns hash { next_due_at, label, status, overdue_minutes }.

class MedicationSchedule
  FREQ_PATTERNS = [
    [ /\bq(\d+)h\b/i,    ->(m) { m[1].to_i * 60 } ],
    [ /\bq(\d+)min\b/i,  ->(m) { m[1].to_i } ],
    [ /\bBID\b/i,        ->(_) { 12 * 60 } ],
    [ /\bTID\b/i,        ->(_) {  8 * 60 } ],
    [ /\bQID\b/i,        ->(_) {  6 * 60 } ],
    [ /\bqhs\b/i,        ->(_) { 24 * 60 } ],
    [ /\bonce daily\b/i, ->(_) { 24 * 60 } ],
    [ /\bdaily\b/i,      ->(_) { 24 * 60 } ]
  ].freeze

  def self.interval_minutes(freq_str)
    FREQ_PATTERNS.each do |pat, fn|
      m = freq_str.to_s.match(pat)
      return fn.call(m) if m
    end
    nil
  end

  # Returns { next_due_at:, label:, status: :upcoming | :overdue | :available | :unknown, minutes: <int or nil> }
  def self.for(order, logs = nil)
    logs    ||= order.medication_logs.to_a
    last      = logs.max_by(&:administered_at)
    interval  = interval_minutes(order.frequency)
    now       = Time.current

    # PRN orders with no prior admin → "available now" (family can request anytime)
    if order.prn && last.nil?
      return { next_due_at: nil, label: "Available now (PRN)", status: :available, minutes: 0 }
    end

    if interval.nil?
      return { next_due_at: nil, label: "Schedule TBD", status: :unknown, minutes: nil }
    end

    next_due = (last&.administered_at || order.start_date&.to_time || now) + interval.minutes
    delta_m  = ((next_due - now) / 60).to_i

    if delta_m < 0
      { next_due_at: next_due, label: "Overdue by #{format_duration(-delta_m)}", status: :overdue, minutes: delta_m }
    elsif delta_m <= 15
      { next_due_at: next_due, label: "Due now", status: :available, minutes: delta_m }
    else
      { next_due_at: next_due, label: "Due in #{format_duration(delta_m)}", status: :upcoming, minutes: delta_m }
    end
  end

  def self.format_duration(mins)
    return "#{mins} min" if mins < 60
    h = mins / 60
    m = mins % 60
    m.zero? ? "#{h}h" : "#{h}h #{m}m"
  end
end
