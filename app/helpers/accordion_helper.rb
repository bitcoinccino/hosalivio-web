module AccordionHelper
  # Readable label for Patient#benefit_period (enum key: bp1_90, bp2_90, bp3_60n).
  # bp3_60n means "third and subsequent 60-day periods, renewable."
  def benefit_period_label(bp)
    case bp.to_s
    when "bp1_90"  then "BP1 · 90d"
    when "bp2_90"  then "BP2 · 90d"
    when "bp3_60n" then "BP3 · 60d+"
    when "", nil   then "—"
    else bp.to_s.tr("_", " ").upcase
    end
  end

  # Family-friendly plain-English explanation of a benefit period.
  # Only shown to family users as a tooltip; clinicians don't need it.
  def benefit_period_explanation(bp, first_name = "your loved one")
    base = "Medicare hospice time period. Every 60 to 90 days the doctor must re-confirm that #{first_name} still qualifies for hospice care."
    case bp.to_s
    when "bp1_90"  then "First 90 days of hospice care. #{base}"
    when "bp2_90"  then "Second 90-day period. #{base}"
    when "bp3_60n" then "Third and later 60-day periods. These can be renewed as long as the doctor keeps confirming eligibility. #{base}"
    else base
    end
  end

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
