module ClinicalChartsHelper
  # ── Sparkline ───────────────────────────────────────────────────────
  # Renders a tiny inline SVG trend line for a numeric series.
  # series   : Array of numeric values (nils allowed — skipped)
  # width/height : SVG dimensions in px
  # stroke   : line color (string)
  # normal_range : [low, high] — values outside tint the final dot red
  def sparkline(series, width: 80, height: 20, stroke: "#2F6F4E", normal_range: nil)
    points = Array(series).each_with_index.map { |v, i| [ i, v ] }.reject { |_, v| v.nil? }
    return tag.span("—", class: "text-[#6B665F] text-[11px] font-mono") if points.size < 2

    vals = points.map { |(_, v)| v }
    vmin, vmax = vals.min, vals.max
    span = (vmax - vmin).to_f
    span = 1.0 if span.zero?

    xmax = points.last[0].to_f
    xmax = 1.0 if xmax.zero?

    coords = points.map do |(i, v)|
      x = (i / xmax) * (width - 2) + 1
      y = height - 1 - ((v - vmin) / span) * (height - 2)
      "#{x.round(2)},#{y.round(2)}"
    end.join(" ")

    last_val  = vals.last
    last_x, last_y = coords.split(" ").last.split(",")
    abnormal = normal_range && (last_val < normal_range.first || last_val > normal_range.last)
    dot_fill = abnormal ? "#C1403A" : stroke

    content_tag(:svg, viewBox: "0 0 #{width} #{height}", width: width, height: height, class: "inline-block align-middle") do
      safe_join([
        tag.polyline(points: coords, fill: "none", stroke: stroke, "stroke-width": 1.5, "stroke-linecap": "round", "stroke-linejoin": "round"),
        tag.circle(cx: last_x, cy: last_y, r: 2, fill: dot_fill)
      ])
    end
  end

  # ── 12-hour medication ribbon ──────────────────────────────────────
  # Renders a horizontal timeline from (now - window_hours) → now, with:
  # - vertical lines for each MedicationLog (administered dose)
  # - an orange "next due" marker if the headline order is due within the window
  # - dotted divider every 3 hours
  def med_timeline_ribbon(logs:, window_hours:, headline_next_due: nil, width: 280, height: 44)
    now        = Time.current
    window     = window_hours.hours
    window_start = now - window
    pad        = 6
    inner_w    = width - pad * 2

    x_for = ->(t) {
      return nil if t < window_start
      frac = (t - window_start).to_f / window
      (pad + frac * inner_w).clamp(pad, width - pad)
    }

    content_tag(:svg, viewBox: "0 0 #{width} #{height}", width: width, height: height, class: "block") do
      parts = []
      # Axis
      parts << tag.line(x1: pad, y1: height - 10, x2: width - pad, y2: height - 10, stroke: "#D9D5CD", "stroke-width": 1)

      # 3-hour ticks
      (1..(window_hours / 3 - 1)).each do |i|
        tx = pad + (i * 3.0 / window_hours) * inner_w
        parts << tag.line(x1: tx, y1: 6, x2: tx, y2: height - 10, stroke: "#EFECE6", "stroke-width": 1, "stroke-dasharray": "2 2")
      end

      # Start/end labels
      parts << tag.text((window_start.strftime("%-l%P")), x: pad, y: height - 1, fill: "#6B665F", "font-size": 9, "font-family": "ui-monospace, monospace")
      parts << tag.text("now", x: width - pad, y: height - 1, fill: "#6B665F", "font-size": 9, "font-family": "ui-monospace, monospace", "text-anchor": "end")

      # Dose markers
      logs.each do |log|
        x = x_for.call(log.administered_at)
        next unless x
        parts << tag.line(x1: x, y1: 6, x2: x, y2: height - 10, stroke: "#2F6F4E", "stroke-width": 2, "stroke-linecap": "round")
        parts << tag.circle(cx: x, cy: 6, r: 2.5, fill: "#2F6F4E")
      end

      # Next-due marker (if within window)
      if headline_next_due && headline_next_due <= now + window
        x = x_for.call(headline_next_due)
        x ||= width - pad    # if it's in the future beyond window, pin right edge (but clamp handles it)
        color = headline_next_due < now ? "#C1403A" : "#D97757"
        parts << tag.line(x1: x, y1: 6, x2: x, y2: height - 10, stroke: color, "stroke-width": 2, "stroke-dasharray": "3 2")
        parts << tag.circle(cx: x, cy: 6, r: 3.5, fill: color)
      end

      safe_join(parts)
    end
  end
end
