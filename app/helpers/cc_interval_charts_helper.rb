module CcIntervalChartsHelper
  CC_INPUT = "w-full px-2 py-1.5 rounded-md border border-[#D9D5CD] bg-[#FBF9F5] " \
             "focus:bg-white focus:border-[#D97757] focus:outline-none text-[13px]".freeze
  CC_LABEL = "block text-[10px] font-semibold uppercase tracking-wider text-[#6B665F] mb-0.5".freeze

  def cc_input = CC_INPUT
  def cc_label = CC_LABEL

  # Orange section header to match the app palette (replaces the reference
  # template's gray/blue bars).
  def cc_section(title)
    content_tag(:h3, title,
      class: "bg-[#D97757] text-white px-3 py-1.5 text-[12px] font-bold uppercase tracking-wider rounded-t")
  end
end
