import { Controller } from "@hotwired/stimulus"

// Team-channel message thread: collapse/expand replies and reveal the inline
// reply composer. One controller per root message.
export default class extends Controller {
  static targets = ["replies", "form", "chevron"]

  toggleReplies() {
    if (!this.hasRepliesTarget) return
    this.repliesTarget.classList.toggle("hidden")
    if (this.hasChevronTarget) this.chevronTarget.classList.toggle("rotate-180")
  }

  openReply() {
    if (!this.hasFormTarget) return
    this.formTarget.classList.remove("hidden")
    const input = this.formTarget.querySelector("input[name='body']")
    if (input) input.focus()
  }

  closeReply() {
    if (this.hasFormTarget) this.formTarget.classList.add("hidden")
  }
}
