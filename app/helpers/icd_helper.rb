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
  #   <%= explain_icd(note.body, emphasize: is_ai) %>          # bold key clinical tokens
  #
  # `emphasize:` bolds a known vocabulary of load-bearing tokens (visit
  # statuses, code status, blocker / missing-doc counts) so HosAlivio's
  # status answers are scannable. Gated to bot messages by the caller; we
  # don't want to bold "scheduled" in a family member's casual sentence.
  def explain_icd(text, audience: nil, emphasize: false)
    return "".html_safe if text.blank?
    audience ||= (current_user&.family_access? ? :family : :clinical)
    safe = ERB::Util.html_escape(text.to_s)
    safe = highlight_keywords(safe) if emphasize

    replaced = safe.gsub(ICD10_REGEX) do
      code = Regexp.last_match(1)
      render_icd_token(code, audience: audience)
    end

    highlight_chat_mentions(replaced).html_safe
  end

  # Bold a small, fixed vocabulary of clinical keywords for scannability.
  # Runs on the already-escaped string, BEFORE ICD / @mention tokenization,
  # so there are no HTML tags yet to match inside — the patterns only ever
  # see plain prose. The inserted <strong> is trusted markup that survives
  # the final .html_safe. Deterministic (no LLM trust) and additive: the
  # model keeps emitting plain text; the view does the highlighting, same
  # as the ICD and @mention passes.
  #
  # KEYWORD_PATTERNS order matters only in that none of the alternatives
  # overlap, so each pass is independent.
  KEYWORD_PATTERNS = [
    # Visit / eval statuses (the words PatientContextBuilder emits).
    /\b(completed|in progress|scheduled|draft)\b/i,
    # Code status.
    /\b(DNR|DNI|DNAR|full code)\b/i,
    # Counts: "2 open blockers", "Missing documents (4)".
    /\b(\d+\s+open\s+blockers?)\b/i,
    /\b(missing documents?\s*\(\d+\))/i
  ].freeze

  def highlight_keywords(html)
    KEYWORD_PATTERNS.reduce(html) do |str, pattern|
      str.gsub(pattern) { %(<strong class="font-semibold">#{Regexp.last_match(1)}</strong>) }
    end
  end

  # @mentions in a message body. @HosAlivio gets the brand color + bot icon
  # (so the AI is instantly recognizable even inside a human's message);
  # any other @handle (@Pascal, @DON, @RN) is highlighted like a name. Runs
  # after ICD tokenization on the already-escaped string; the handle is \w+
  # so there's nothing to inject. Safe to no-op when there are no mentions.
  MENTION_RE = /@(\w+)/
  def highlight_chat_mentions(html)
    html.gsub(MENTION_RE) do
      handle = Regexp.last_match(1)
      if handle.casecmp?("hosalivio")
        %(<span class="inline-flex items-center gap-0.5 font-semibold text-[#D97757]">) +
          %(<i class="ri-heart-pulse-line text-[11px]"></i>@#{handle}</span>)
      else
        %(<span class="font-semibold text-[#2B4A7A]">@#{handle}</span>)
      end
    end
  end

  # Render a single ICD code (no surrounding prose) — useful for diagnosis
  # fields where the value is just the code.
  def explain_icd_code(code, audience: nil)
    return "".html_safe if code.blank?
    audience ||= (current_user&.family_access? ? :family : :clinical)
    render_icd_token(code.to_s.strip, audience: audience).html_safe
  end

  # Plain-English definition for a code, for clinician views (no
  # tooltip wrapper). Falls back to the `description` text from the
  # eval JSON when the explanation table doesn't have a row for the
  # code yet.
  def icd_definition(code, fallback_description = nil)
    exp = Icd10Explanation.lookup(code)
    return [ exp.simple_description, exp.hospice_context ].compact_blank.join(" — ") if exp
    fallback_description.to_s.presence
  end

  # Pull supporting sentences out of `narrative` that mention the
  # given diagnosis. Two-stage match: keywords from the friendly
  # description + a curated map of ICD-10 prefix → common synonyms
  # so a code like E11.9 still surfaces sentences talking about
  # "blood sugar" or "insulin", not just "diabetes".
  def icd_evidence(code, description, narrative, limit: 2)
    return [] if narrative.blank?
    keys = icd_evidence_keywords(code, description)
    return [] if keys.empty?
    narrative.split(/(?<=[.!?])\s+/).map(&:strip).reject(&:blank?).select do |s|
      lower = s.downcase
      keys.any? { |k| lower.include?(k) }
    end.first(limit)
  end

  ICD_PREFIX_KEYWORDS = {
    /\AE1[0-3]/  => %w[diabetes diabetic glucose insulin a1c hyperglyc hypoglyc blood sugar],
    /\AE08|\AE09/ => %w[diabetes diabetic glucose],
    /\AI50/      => %w[chf heart failure ejection fraction edema dyspnea],
    /\AJ44/      => %w[copd emphysema bronchitis dyspnea oxygen],
    /\AC/        => %w[cancer tumor metastat malignan chemo radiation],
    /\AG30/      => %w[alzheimer dementia memory cognitive],
    /\AF0[123]/  => %w[dementia memory cognitive confusion],
    /\AI6[0-7]/  => %w[stroke cva hemiparesis hemiplegia],
    /\AN18/      => %w[kidney renal dialysis creatinine],
    /\AK7[024]/  => %w[liver hepatic cirrhosis ascites],
    /\AI10|\AI11/ => %w[hypertension blood pressure],
    /\AJ96/      => %w[respiratory failure oxygen ventilator]
  }.freeze

  ICD_STOPWORDS = %w[with without other unspecified type stage acute chronic primary secondary disease syndrome condition end-stage end stage].freeze

  def icd_evidence_keywords(code, description)
    desc_words = description.to_s.downcase.scan(/[a-z]{4,}/).reject { |w| ICD_STOPWORDS.include?(w) }.uniq
    prefix_keywords = ICD_PREFIX_KEYWORDS.find { |re, _| code.to_s.upcase.match?(re) }&.last || []
    (desc_words + prefix_keywords).uniq
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
