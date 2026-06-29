module PatientChatsHelper
  # One consistent chat avatar for every role across bubbles and thread
  # replies: the person's uploaded photo when present, otherwise a colored
  # circle with their initials (never a bare icon, so md/rn/family/patient
  # all read the same). HosAlivio (AI) gets the brand bot circle.
  #
  #   <%= chat_avatar_tag(name: speaker_name, user: note.author_user,
  #                       is_ai: is_ai, color: label_color, px: 40) %>
  def chat_avatar_tag(name:, user: nil, is_ai: false, color: "#6B665F", px: 40)
    inner =
      if is_ai
        content_tag(:span, tag.i(class: "ri-heart-pulse-line", style: "font-size:#{(px * 0.5).round}px"),
                    class: "w-full h-full flex items-center justify-center bg-[#D97757] text-white")
      elsif user&.has_avatar?
        image_tag(user.avatar.variant(resize_to_fill: [ px * 2, px * 2 ]).processed,
                  class: "w-full h-full object-cover", alt: name)
      else
        initials = name.to_s.split.map { |w| w[0] }.first(2).join.upcase.presence || "?"
        content_tag(:span, initials,
                    class: "w-full h-full flex items-center justify-center text-white font-semibold",
                    style: "background:#{color};font-size:#{(px * 0.4).round}px")
      end
    content_tag(:span, inner,
                class: "inline-flex flex-shrink-0 rounded-full overflow-hidden",
                style: "width:#{px}px;height:#{px}px")
  end
end
