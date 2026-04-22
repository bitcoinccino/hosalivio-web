module AccordionHelper
  # Renders the <summary> header for a <details> accordion card.
  # Use inside a <details class="group"> ... </details> block.
  #
  #   <details class="group" open>
  #     <%= acc_header("ri-capsule-line", "Active Orders", "3") %>
  #     ...body...
  #   </details>
  def acc_header(icon, title, counter = nil)
    content_tag(:summary,
      class: "flex items-center justify-between px-5 py-3 border-b border-[#EFECE6] cursor-pointer select-none hover:bg-[#FBF9F5] list-none [&::-webkit-details-marker]:hidden",
      role: "button") do
      concat(
        content_tag(:div, class: "flex items-center gap-2") do
          concat content_tag(:i, "", class: "#{icon} text-[#6B665F]")
          concat content_tag(:span, title, class: "text-[11px] uppercase tracking-widest text-[#1D1C1A] font-bold")
          if counter.present?
            concat content_tag(:span, counter, class: "text-[10px] text-[#6B665F] font-mono ml-1")
          end
        end
      )
      concat(
        content_tag(:i, "", class: "ri-arrow-down-s-line text-[#6B665F] group-open:rotate-180 transition-transform")
      )
    end
  end
end
