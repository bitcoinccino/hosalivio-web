module AiRepliesHelper
  def ai_reply_attention_items(text)
    body = text.to_s
    items = []

    blocker_match = body.match(/(?:blockers?|holding .*? draft):\s*(.+?)(?:\.|$)/i)
    if blocker_match
      blocker_match[1].split(/,\s*|\s+and\s+/i).each do |item|
        cleaned = item.to_s.strip.sub(/\A\d+\s*/, "").sub(/\A[:;-]\s*/, "")
        items << cleaned if cleaned.present?
      end
    end

    body.scan(/([^.]*?(?:not signed|not reviewed|missing|unsupported|not supported|in progress|incomplete|needs? to be completed|overdue)[^.]*\.)/i) do |match|
      cleaned = match.first.to_s.strip
      items << cleaned if cleaned.present?
    end

    items.map { |item| item.sub(/\A(?:and|with)\s+/i, "").strip }.uniq.first(5)
  end

  def ai_reply_next_step(text)
    body = text.to_s
    body.match(/(?:next priority|next step|addressing .*? first|once .*?)([^.]*\.)/i)&.then do |match|
      phrase = match[0].strip
      return phrase[0].upcase + phrase[1..].to_s
    end

    body.match(/([^.]*(?:should|needs? to|clear|complete|resolve|flag|notify)[^.]*\.)/i)&.[](1)&.strip
  end

  def ai_reply_fact_chips(text)
    body = text.to_s
    chips = []
    chips << "DNR" if body.match?(/\bDNR\b/i)
    chips << "POLST" if body.match?(/\bPOLST\b/i)

    if (match = body.match(/(\d+)\s+days?\s+into (?:her|his|their)?\s*hospice/i))
      chips << "Day #{match[1]}"
    end

    if (match = body.match(/(\d+)\s+days?\s+to recert/i))
      chips << "#{match[1]}d to recert"
    end

    if (match = body.match(/cert period ends? (\d{4}-\d{2}-\d{2})/i))
      chips << "Cert ends #{match[1]}"
    end

    chips.uniq.first(5)
  end
end
