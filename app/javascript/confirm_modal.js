// Replaces Turbo's default window.confirm() with a styled modal dialog.
// Any link or button_to using data-turbo-confirm="..." will trigger this.
//
// The Turbo docs spec the method as:
//   Turbo.setConfirmMethod((message, formElement, submitter) => Promise<boolean>)

import { Turbo } from "@hotwired/turbo-rails"

const MODAL_ID = "hosalivio-confirm-modal"

function buildModal() {
  const existing = document.getElementById(MODAL_ID)
  if (existing) return existing

  const html = `
<div id="${MODAL_ID}" class="hidden fixed inset-0 z-[100] flex items-center justify-center">
  <div class="absolute inset-0 bg-[#1D1C1A]/40 backdrop-blur-sm" data-role="backdrop"></div>
  <div class="relative w-full max-w-sm mx-4 bg-white rounded-2xl border border-[#EFECE6] shadow-xl overflow-hidden">
    <div class="px-6 pt-5 pb-3 flex items-start gap-3">
      <div class="w-9 h-9 rounded-full bg-[#FFF3EC] text-[#D97757] flex items-center justify-center flex-shrink-0" data-role="icon">
        <i class="ri-question-line text-lg"></i>
      </div>
      <div class="flex-1 pt-0.5 min-w-0">
        <h3 class="text-[15px] font-serif text-[#1D1C1A]" data-role="title">Confirm</h3>
        <p class="text-[13px] text-[#6B665F] mt-1 break-words" data-role="message"></p>
      </div>
    </div>
    <div class="px-6 pb-5 pt-2 flex items-center justify-end gap-2">
      <button type="button" data-role="cancel"
              class="text-[13px] px-4 py-2 rounded-full border border-[#D9D5CD] text-[#1D1C1A] hover:bg-[#FBF9F5]">
        Cancel
      </button>
      <button type="button" data-role="confirm"
              class="text-[13px] px-4 py-2 rounded-full bg-[#D97757] hover:bg-[#c46a4b] text-white font-medium">
        Confirm
      </button>
    </div>
  </div>
</div>
  `.trim()

  const wrapper = document.createElement("div")
  wrapper.innerHTML = html
  const modal = wrapper.firstElementChild
  document.body.appendChild(modal)
  return modal
}

// Parse the confirm text to derive a title + body + destructive intent.
// If the text contains "?" we split at it; first part becomes title, rest is body.
// Destructive verbs flip the Confirm button to red and icon to warning.
function parseMessage(message) {
  const text = (message || "").trim()
  const destructive = /delete|remove|cancel visit|deactivate|sign out|drop/i.test(text)

  let title = text
  let body  = ""
  const qIdx = text.indexOf("?")
  if (qIdx > -1 && qIdx < text.length - 1) {
    title = text.slice(0, qIdx + 1)
    body  = text.slice(qIdx + 1).trim()
  }
  return { title, body, destructive }
}

function showStyledConfirm(message /* , formElement, submitter */) {
  return new Promise((resolve) => {
    const modal     = buildModal()
    const titleEl   = modal.querySelector('[data-role="title"]')
    const messageEl = modal.querySelector('[data-role="message"]')
    const iconEl    = modal.querySelector('[data-role="icon"]')
    const confirmBt = modal.querySelector('[data-role="confirm"]')
    const cancelBt  = modal.querySelector('[data-role="cancel"]')
    const backdrop  = modal.querySelector('[data-role="backdrop"]')

    const { title, body, destructive } = parseMessage(message)
    titleEl.textContent   = title || "Confirm"
    messageEl.textContent = body
    messageEl.classList.toggle("hidden", !body)

    // Swap styling based on destructive intent.
    if (destructive) {
      iconEl.className = "w-9 h-9 rounded-full bg-[#FFF3EC] text-[#C1403A] flex items-center justify-center flex-shrink-0"
      iconEl.innerHTML = '<i class="ri-alert-line text-lg"></i>'
      confirmBt.className = "text-[13px] px-4 py-2 rounded-full bg-[#C1403A] hover:bg-[#a5342f] text-white font-medium"
      confirmBt.textContent = "Yes, continue"
    } else {
      iconEl.className = "w-9 h-9 rounded-full bg-[#FFF3EC] text-[#D97757] flex items-center justify-center flex-shrink-0"
      iconEl.innerHTML = '<i class="ri-question-line text-lg"></i>'
      confirmBt.className = "text-[13px] px-4 py-2 rounded-full bg-[#D97757] hover:bg-[#c46a4b] text-white font-medium"
      confirmBt.textContent = "Confirm"
    }

    modal.classList.remove("hidden")

    const cleanup = (result) => {
      modal.classList.add("hidden")
      confirmBt.removeEventListener("click", onOk)
      cancelBt.removeEventListener("click", onNo)
      backdrop.removeEventListener("click", onNo)
      document.removeEventListener("keydown", onKey)
      resolve(result)
    }
    const onOk  = () => cleanup(true)
    const onNo  = () => cleanup(false)
    const onKey = (e) => {
      if (e.key === "Escape") cleanup(false)
      if (e.key === "Enter")  cleanup(true)
    }

    confirmBt.addEventListener("click", onOk)
    cancelBt.addEventListener("click", onNo)
    backdrop.addEventListener("click", onNo)
    document.addEventListener("keydown", onKey)
    requestAnimationFrame(() => confirmBt.focus())
  })
}

// Turbo 8+: setConfirmMethod takes (message, formElement, submitter).
// Our override returns a Promise resolving to true/false.
if (Turbo && typeof Turbo.setConfirmMethod === "function") {
  Turbo.setConfirmMethod(showStyledConfirm)
}
