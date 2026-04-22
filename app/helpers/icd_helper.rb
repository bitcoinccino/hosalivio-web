module IcdHelper
  # Matches ICD-10 codes in text: one letter + two digits + optional .subcode.
  # Word-boundary anchored so we don't chew into regular words like "A1c".
  ICD10_REGEX = /\b([A-Z]\d{2}(?:\.\w{1,4})?)\b/

  # Scan free text for ICD-10 codes and wrap each one in a tooltip span for
  # family users. Clinicians get a plain font-mono span (no tooltip) since they
  # already know the codes and don't want extra popovers.
  #
  # Usage:
  #   <%= explain_icd(note.body) %>                            # defaults to current_user audience
  #   <%= explain_icd("Dx C50.911 with bone mets", audience: :family) %>
  def explain_icd(text, audience: nil)
    return "".html_safe if text.blank?
    audience ||= (current_user&.family_access? ? :family : :clinical)
    safe = ERB::Util.html_escape(text.to_s)

    replaced = safe.gsub(ICD10_REGEX) do
      code = Regexp.last_match(1)
      render_icd_token(code, audience: audience)
    end

    replaced.html_safe
  end

  # Render a single ICD code (no surrounding prose) — useful for diagnosis
  # fields where the value is just the code.
  def explain_icd_code(code, audience: nil)
    return "".html_safe if code.blank?
    audience ||= (current_user&.family_access? ? :family : :clinical)
    render_icd_token(code.to_s.strip, audience: audience).html_safe
  end

  private

  def render_icd_token(code, audience:)
    if audience == :family
      exp = Icd10Explanation.lookup(code)
      if exp
        content_tag(:span, code,
          class: "icd-code underline decoration-dotted decoration-[#6B665F] underline-offset-2 cursor-help font-mono",
          data:  {
            controller: "tooltip",
            tooltip_content_value: exp.tooltip_text,
            action: "mouseenter->tooltip#show mouseleave->tooltip#hide focus->tooltip#show blur->tooltip#hide click->tooltip#toggle"
          },
          tabindex: 0,
          role: "button",
          "aria-label": "Explain code #{code}: #{exp.simple_description}"
        )
      else
        # Unknown code — tell family it's a billing code, don't guess.
        content_tag(:span, code,
          class: "icd-code underline decoration-dotted decoration-[#B9B4AB] underline-offset-2 cursor-help font-mono",
          data: {
            controller: "tooltip",
            tooltip_content_value: "This is a medical billing code. Ask the nurse to explain it in plain English.",
            action: "mouseenter->tooltip#show mouseleave->tooltip#hide focus->tooltip#show blur->tooltip#hide click->tooltip#toggle"
          },
          tabindex: 0
        )
      end
    else
      # Clinician view: plain mono, no tooltip.
      content_tag(:span, code, class: "font-mono")
    end
  end
end
