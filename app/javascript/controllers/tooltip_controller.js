import { Controller } from "@hotwired/stimulus"

// Family-friendly ICD-10 tooltip.
// Renders a single globally-reused tooltip element; positions it above the
// trigger element. Works for hover (desktop) and click/tap (mobile).
//
// Markup:
//   <span data-controller="tooltip"
//         data-tooltip-content-value="Heart failure. We focus on breathing and rest."
//         data-action="mouseenter->tooltip#show mouseleave->tooltip#hide click->tooltip#toggle">
//     I50.9
//   </span>
export default class extends Controller {
  static values = { content: String }

  connect() {
    this.ensureTip()
  }

  ensureTip() {
    if (document.getElementById("hosalivio-tooltip")) return
    const tip = document.createElement("div")
    tip.id = "hosalivio-tooltip"
    tip.className = [
      "hidden fixed z-[200] pointer-events-none",
      "max-w-xs px-3 py-2 rounded-lg",
      "bg-[#1D1C1A] text-white text-[12px] leading-snug",
      "shadow-lg"
    ].join(" ")
    tip.innerHTML = `
      <div data-role="body"></div>
      <div data-role="arrow" class="absolute left-1/2 -translate-x-1/2 top-full w-0 h-0"
           style="border-left: 6px solid transparent; border-right: 6px solid transparent; border-top: 6px solid #1D1C1A;"></div>
    `
    document.body.appendChild(tip)
  }

  show() {
    const tip  = document.getElementById("hosalivio-tooltip")
    const body = tip.querySelector('[data-role="body"]')
    body.textContent = this.contentValue

    tip.classList.remove("hidden")
    const rect = this.element.getBoundingClientRect()
    // Measure after unhiding
    const tipRect = tip.getBoundingClientRect()
    let left = rect.left + rect.width / 2 - tipRect.width / 2
    let top  = rect.top - tipRect.height - 8

    // Keep on screen horizontally
    const margin = 8
    if (left < margin) left = margin
    if (left + tipRect.width > window.innerWidth - margin) {
      left = window.innerWidth - margin - tipRect.width
    }
    // Flip below if no room above
    if (top < margin) {
      top = rect.bottom + 8
      const arrow = tip.querySelector('[data-role="arrow"]')
      arrow.style.top    = "auto"
      arrow.style.bottom = "100%"
      arrow.style.borderTop    = "none"
      arrow.style.borderBottom = "6px solid #1D1C1A"
    } else {
      const arrow = tip.querySelector('[data-role="arrow"]')
      arrow.style.top    = "100%"
      arrow.style.bottom = "auto"
      arrow.style.borderTop    = "6px solid #1D1C1A"
      arrow.style.borderBottom = "none"
    }
    tip.style.left = `${left}px`
    tip.style.top  = `${top}px`
  }

  hide() {
    const tip = document.getElementById("hosalivio-tooltip")
    if (tip) tip.classList.add("hidden")
  }

  toggle(event) {
    const tip = document.getElementById("hosalivio-tooltip")
    if (!tip || tip.classList.contains("hidden")) {
      this.show()
    } else {
      this.hide()
    }
  }
}
