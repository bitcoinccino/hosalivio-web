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

  # Privacy-mask an email for display on sign-in confirmation pages.
  # Keeps the first and last character of the local part + the full
  # domain, so 'family@hosalivio.com' reads as 'f****y@hosalivio.com'.
  def mask_email(email)
    s = email.to_s.strip
    return "" if s.empty?
    local, domain = s.split("@", 2)
    return s if domain.blank?
    if local.length <= 2
      masked_local = "#{local[0]}*"
    else
      masked_local = "#{local[0]}#{"*" * [ local.length - 2, 4 ].min}#{local[-1]}"
    end
    "#{masked_local}@#{domain}"
  end

  # Render an audit-trace body, escaping HTML and turning every @Name
  # token into a clickable button. The button triggers the patient-chat
  # Stimulus action `mention` which inserts "@Name " into the input
  # and auto-flips the visibility toggle to "Internal team only".
  #
  # The viewer's own name renders as plain (non-clickable) text — Esther
  # shouldn't see herself as a tappable target since she can't ping
  # herself.
  def render_audit_body(body)
    return "" if body.blank?
    me = viewer_mention_name
    esc = ERB::Util.html_escape(body.to_s)
    esc.gsub(/@(\w+)/) do |_|
      name = Regexp.last_match(1)
      if me && name.casecmp(me).zero?
        %Q(<span class="font-medium text-[#6B665F]" title="That's you">@#{name}</span>)
      else
        <<~HTML.delete("\n")
          <button type="button"
                  class="font-medium text-[#D97757] hover:underline cursor-pointer"
                  data-action="click->patient-chat#mention"
                  data-mention="#{name}"
                  title="Reply to #{name} (private team note)">@#{name}</button>
        HTML
      end
    end.html_safe
  end

  # First-name token of the current viewer with honorifics stripped, used
  # to suppress self-mention buttons. Mirrors HosalivioTriager's
  # first_name_for_mention so server and audit emitters agree on what
  # "Esther" looks like.
  HONORIFIC_TOKENS = %w[dr. mr. mrs. ms. mx. rev. fr. sr.].freeze
  def viewer_mention_name
    name = current_user&.full_name.to_s
    return nil if name.blank?
    tokens = name.split.reject { |t| HONORIFIC_TOKENS.include?(t.downcase) }
    tokens.first || name.split.first
  end

  # Human-friendly relative date label used to anchor chat-feed sections,
  # event timelines, and any other surface where "April 22" reads colder
  # than "Today" or "Yesterday".
  #
  # "Today"/"Yesterday" stand alone because they're unambiguous. A bare weekday
  # isn't — "Monday" could be 2 days ago or 6, and a reader scrolling a timeline
  # has no way to tell — so it carries its date.
  def relative_date_label(date_or_time)
    return "" if date_or_time.nil?
    date  = date_or_time.respond_to?(:to_date) ? date_or_time.to_date : date_or_time
    today = Date.current

    if date == today
      "Today"
    elsif date == today - 1
      "Yesterday"
    elsif date >= today - 6 && date < today
      date.strftime("%A · %B %-d")
    elsif date.year == today.year
      date.strftime("%B %-d")
    else
      date.strftime("%B %-d, %Y")
    end
  end
end
