module ApplicationHelper
  # Patient's branch timezone, falling back gracefully so we never crash
  # when a patient is mid-onboarding without a branch yet.
  def patient_timezone(patient)
    patient&.branch&.timezone.presence ||
      Current.agency&.branches&.first&.timezone.presence ||
      "America/New_York"
  end

  # Render a Time/DateTime in the patient's branch timezone using the given
  # strftime format. Replaces bare note.created_at.strftime calls in the
  # chat feed so server-rendered times match Cable-streamed ones.
  def in_patient_zone(time, patient, fmt = "%-l:%M %p")
    return "" if time.nil?
    time.in_time_zone(patient_timezone(patient)).strftime(fmt)
  end

  # Respectful "Ms. Maria" / "Mr. Robert" form for greeting copy. Falls
  # back to plain first name when gender is unknown (or other) so we never
  # mislabel.
  def patient_salutation(patient)
    first = patient&.first_name.to_s.strip
    return "" if first.blank?
    g = patient.gender.to_s.downcase.strip
    if g.start_with?("f")
      "Ms. #{first}"
    elsif g.start_with?("m")
      "Mr. #{first}"
    else
      first
    end
  end

  # Render an audit-trace body, escaping HTML and turning every @Name
  # token into a clickable button. The button triggers the patient-chat
  # Stimulus action `mention` which inserts "@Name " into the input
  # and auto-flips the visibility toggle to "Internal team only".
  def render_audit_body(body)
    return "" if body.blank?
    esc = ERB::Util.html_escape(body.to_s)
    esc.gsub(/@(\w+)/) do |_|
      name = Regexp.last_match(1)
      ERB::Util.html_escape(name)
      <<~HTML.delete("\n")
        <button type="button"
                class="font-medium text-[#D97757] hover:underline cursor-pointer"
                data-action="click->patient-chat#mention"
                data-mention="#{name}"
                title="Reply to #{name} (private team note)">@#{name}</button>
      HTML
    end.html_safe
  end

  # Human-friendly relative date label used to anchor chat-feed sections,
  # event timelines, and any other surface where "April 22" reads colder
  # than "Today" or "Yesterday".
  def relative_date_label(date_or_time)
    return "" if date_or_time.nil?
    date  = date_or_time.respond_to?(:to_date) ? date_or_time.to_date : date_or_time
    today = Date.current

    if date == today
      "Today"
    elsif date == today - 1
      "Yesterday"
    elsif date >= today - 6 && date < today
      date.strftime("%A")
    elsif date.year == today.year
      date.strftime("%B %-d")
    else
      date.strftime("%B %-d, %Y")
    end
  end
end
