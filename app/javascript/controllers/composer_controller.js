import { Controller } from "@hotwired/stimulus"

// Mission Stage composer: flips a single input between two modes.
//
//   ask     → POST to HosAlivio; the answer streams into the
//             "assistant-answer" turbo-frame (stays on the page).
//   channel → POST a message to a team channel; the channels controller
//             redirects into that channel's team chat.
//
// Picking a channel in the "+" modal calls channel(); the × on the mode
// chip (or a fresh load) calls ask().
export default class extends Controller {
  static targets = ["form", "input", "chip", "chipLabel", "hint", "quickAsks"]
  static values = { askUrl: String, askPlaceholder: String }

  channel(event) {
    if (event) event.preventDefault()
    const el   = event.currentTarget
    const slug = el.dataset.channelSlug

    this.formTarget.setAttribute("action", el.dataset.channelUrl)
    this.inputTarget.name = "body"
    this.inputTarget.placeholder = `Message #${slug} — @ to tag a teammate…`

    this.chipLabelTarget.textContent = `# ${slug}`
    this.chipTarget.classList.remove("hidden")
    if (this.hasHintTarget) this.hintTarget.classList.add("hidden")
    // Oversight quick-asks are Ask-HosAlivio shortcuts — irrelevant here.
    if (this.hasQuickAsksTarget) this.quickAsksTarget.classList.add("hidden")

    const dlg = el.closest("dialog")
    if (dlg && dlg.open) dlg.close()
    this.inputTarget.focus()
  }

  ask(event) {
    if (event) event.preventDefault()
    this.formTarget.setAttribute("action", this.askUrlValue)
    this.inputTarget.name = "q"
    this.inputTarget.placeholder = this.askPlaceholderValue
    this.inputTarget.value = ""

    this.chipTarget.classList.add("hidden")
    if (this.hasHintTarget) this.hintTarget.classList.remove("hidden")
    if (this.hasQuickAsksTarget) this.quickAsksTarget.classList.remove("hidden")
    this.inputTarget.focus()
  }
}
