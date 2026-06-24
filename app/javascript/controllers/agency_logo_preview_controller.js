import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "image", "placeholder", "filename"]

  connect() {
    this.objectUrl = null
  }

  disconnect() {
    this._revokeObjectUrl()
  }

  preview() {
    if (!this.hasInputTarget) return
    const file = this.inputTarget.files && this.inputTarget.files[0]
    if (!file) return

    this._revokeObjectUrl()
    this.objectUrl = URL.createObjectURL(file)

    this.imageTargets.forEach((image) => {
      image.src = this.objectUrl
      image.alt = file.name
      image.classList.remove("hidden")
    })

    this.placeholderTargets.forEach((placeholder) => {
      placeholder.classList.add("hidden")
    })

    this.filenameTargets.forEach((target) => {
      target.textContent = file.name
      target.classList.remove("hidden")
    })
  }

  _revokeObjectUrl() {
    if (!this.objectUrl) return
    URL.revokeObjectURL(this.objectUrl)
    this.objectUrl = null
  }
}
