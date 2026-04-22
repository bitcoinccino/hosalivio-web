import { Controller } from "@hotwired/stimulus"

// Horizontal scroll carousel with prev/next buttons.
// Usage: data-controller="carousel" with a data-carousel-target="track"
// element that is `overflow-x-auto`. Prev/next buttons fire
// data-action="click->carousel#prev" / #next.
export default class extends Controller {
  static targets = ["track"]

  prev() {
    this._scrollBy(-1)
  }

  next() {
    this._scrollBy(1)
  }

  // Big slide — reveal the next batch of cards (approx 3 at a time).
  showMore() {
    this._scrollBy(3)
  }

  _scrollBy(direction) {
    if (!this.hasTrackTarget) return
    const track = this.trackTarget
    // Scroll by one card width + gap, approximated from the first card.
    const firstCard = track.querySelector("article, .snap-start")
    const step = firstCard
      ? firstCard.getBoundingClientRect().width + 16  // 16 ≈ gap-4
      : Math.round(track.clientWidth * 0.8)
    track.scrollBy({ left: step * direction, behavior: "smooth" })
  }
}
