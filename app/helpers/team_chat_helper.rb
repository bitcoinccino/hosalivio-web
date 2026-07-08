module TeamChatHelper
  # Role → avatar color, matching the patient-chat message bubble palette.
  TEAM_ROLE_COLOR = {
    "rn" => "#2F6F4E", "visit_rn" => "#2F6F4E", "lpn" => "#3A8C6E",
    "md" => "#2B4A7A", "social_worker" => "#7A4A8C", "sw" => "#7A4A8C",
    "chaplain" => "#8C6A2F", "pharmacy" => "#5A2F7A", "aide" => "#3A6B6B",
    "don" => "#1D1C1A", "dme" => "#6B5A2F", "insurance" => "#4A4A6B",
    "billing" => "#6B665F", "admissions" => "#6B665F", "admin" => "#1D1C1A"
  }.freeze

  TEAM_ROLE_LABEL = {
    "rn" => "RN", "visit_rn" => "Visit RN", "lpn" => "LPN", "md" => "MD",
    "social_worker" => "Social Work", "sw" => "Social Work", "chaplain" => "Chaplain",
    "pharmacy" => "Pharmacy", "aide" => "Aide", "don" => "DON", "dme" => "DME",
    "insurance" => "Insurance", "billing" => "Billing", "admissions" => "Admissions",
    "admin" => "Admin"
  }.freeze

  ROLE_PRIORITY = %w[admin md rn visit_rn lpn admissions social_worker sw chaplain
                     pharmacy dme insurance billing aide].freeze

  # The role we show for a user in team chat: their highest-priority role.
  def team_primary_role(user)
    (ROLE_PRIORITY & user.role_names.to_a).first || user.role_names.to_a.first
  end

  def team_role_color(role) = TEAM_ROLE_COLOR.fetch(role.to_s, "#6B665F")
  def team_role_label(role) = TEAM_ROLE_LABEL[role.to_s] || role.to_s.titleize

  def team_avatar_initials(user)
    user.full_name.to_s.split.map(&:first).first(2).join.upcase.presence || "?"
  end

  # Renders @Handle mentions in a message body as subtle chips, escaping the
  # rest. Handles are @Firstname tokens (matching ChannelMessage mention logic).
  def team_format_body(body)
    escaped = ERB::Util.html_escape(body.to_s)
    escaped.gsub(/(?<=\A|\s)@(\w+)/) do
      %(<span class="text-[#2B4A7A] font-medium">@#{Regexp.last_match(1)}</span>)
    end.html_safe
  end
end
