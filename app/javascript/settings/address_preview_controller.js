import { Controller } from "@hotwired/stimulus"

// New agent: as the name or the address is typed, the frame under them asks
// the server for the address the agent would get, or why it can't have it,
// since only the server knows which are taken. Until the person types an
// address of their own, the address follows the name.
export default class extends Controller {
  static targets = [ "name", "address", "frame" ]
  static values = { url: String, chosen: Boolean }

  disconnect() { clearTimeout(this.timer) }

  choose() {
    this.chosenValue = this.addressTarget.value.trim() !== ""
    this.preview()
  }

  preview() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      const url = new URL(this.urlValue, window.location.href)
      url.searchParams.set("name", this.nameTarget.value)
      if (this.chosenValue && this.hasAddressTarget) url.searchParams.set("email_name", this.addressTarget.value)
      this.frameTarget.src = url.toString()
    }, 250)
  }

  suggest() {
    const suggestion = this.frameTarget.querySelector("[data-suggestion]")?.dataset.suggestion
    if (!this.chosenValue && this.hasAddressTarget && suggestion !== undefined) this.addressTarget.value = suggestion
  }
}
