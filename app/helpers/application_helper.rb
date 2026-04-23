module ApplicationHelper
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
