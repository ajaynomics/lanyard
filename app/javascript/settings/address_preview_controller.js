import { Controller } from "@hotwired/stimulus"

// New agent: as the name or the address is typed, the frame under them asks
// the server for the address the agent would get, or why it can't have it,
// since only the server knows which are taken. Until the person types an
// address of their own, the address follows the name.
//
// It fetches the frame itself rather than setting its src: a Turbo frame
// renders a response it had already read even after a newer one replaced
// it, so an older check ("taken") could paint over the latest.
export default class extends Controller {
  static targets = [ "name", "address", "frame" ]
  static values = { url: String, chosen: Boolean }

  disconnect() { this.cancelPreview() }

  choose() {
    this.chosenValue = this.addressTarget.value.trim() !== ""
    this.preview()
  }

  preview() {
    this.cancelPreview()
    this.abortController = new AbortController()
    const { signal } = this.abortController
    this.timer = setTimeout(() => this.loadPreview(signal), 250)
  }

  cancelPreview() {
    clearTimeout(this.timer)
    this.abortController?.abort()
  }

  async loadPreview(signal) {
    const frame = this.frameTarget
    const url = new URL(this.urlValue, window.location.href)
    url.searchParams.set("name", this.nameTarget.value)
    if (this.chosenValue && this.hasAddressTarget) url.searchParams.set("email_name", this.addressTarget.value)

    try {
      const response = await fetch(url, { headers: { "Turbo-Frame": frame.id }, signal })
      if (!response.ok) return

      const html = await response.text()
      // Cancel alone cannot stop a response that was already buffered.
      if (signal.aborted || !frame.isConnected) return

      const preview = new DOMParser().parseFromString(html, "text/html").getElementById(frame.id)
      if (!preview) return

      frame.replaceChildren(...preview.childNodes)
      this.suggest()
    } catch (error) {
      if (!signal.aborted) console.warn("Could not check the agent address", error)
    }
  }

  suggest() {
    const suggestion = this.frameTarget.querySelector("[data-suggestion]")?.dataset.suggestion
    if (!this.chosenValue && this.hasAddressTarget && suggestion !== undefined) this.addressTarget.value = suggestion
  }
}
