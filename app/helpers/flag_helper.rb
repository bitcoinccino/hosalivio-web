# Inline SVG flag icons for the language picker. Simple, dependency-
# free, render identically across browsers / OSes (emoji flags don't —
# Windows ships zero glyphs for them and falls back to country codes).
# Sized for the 24x16 rectangle the picker uses; scale via CSS.
module FlagHelper
  FLAGS = {
    "en" => <<~SVG.squish.html_safe,
      <svg viewBox="0 0 24 16" xmlns="http://www.w3.org/2000/svg" class="w-5 h-3.5 rounded-sm shrink-0 inline-block align-middle">
        <rect width="24" height="16" fill="#B22234"/>
        <g fill="#FFFFFF">
          <rect y="1.23" width="24" height="1.23"/>
          <rect y="3.69" width="24" height="1.23"/>
          <rect y="6.15" width="24" height="1.23"/>
          <rect y="8.62" width="24" height="1.23"/>
          <rect y="11.08" width="24" height="1.23"/>
          <rect y="13.54" width="24" height="1.23"/>
        </g>
        <rect width="9.6" height="8.62" fill="#3C3B6E"/>
      </svg>
    SVG
    "es" => <<~SVG.squish.html_safe,
      <svg viewBox="0 0 24 16" xmlns="http://www.w3.org/2000/svg" class="w-5 h-3.5 rounded-sm shrink-0 inline-block align-middle">
        <rect width="24" height="16" fill="#AA151B"/>
        <rect y="4" width="24" height="8" fill="#F1BF00"/>
      </svg>
    SVG
    "ht" => <<~SVG.squish.html_safe,
      <svg viewBox="0 0 24 16" xmlns="http://www.w3.org/2000/svg" class="w-5 h-3.5 rounded-sm shrink-0 inline-block align-middle">
        <rect width="24" height="8" fill="#00209F"/>
        <rect y="8" width="24" height="8" fill="#D21034"/>
        <rect x="9" y="5" width="6" height="6" fill="#FFFFFF"/>
      </svg>
    SVG
    "pt" => <<~SVG.squish.html_safe
      <svg viewBox="0 0 24 16" xmlns="http://www.w3.org/2000/svg" class="w-5 h-3.5 rounded-sm shrink-0 inline-block align-middle">
        <rect width="24" height="16" fill="#009C3B"/>
        <polygon points="12,2 22,8 12,14 2,8" fill="#FFDF00"/>
        <circle cx="12" cy="8" r="3" fill="#002776"/>
      </svg>
    SVG
  }.freeze

  def language_flag(code)
    FLAGS[code.to_s] || FLAGS["en"]
  end
end
