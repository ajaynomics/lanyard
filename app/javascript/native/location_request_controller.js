import { BridgeComponent } from "@hotwired/hotwire-native-bridge"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends BridgeComponent {
  static component = "phone-location"
  static targets = [ "share", "noPhone", "status" ]
  static values = { url: String, conversation: String, invocation: String }

  connect() {
    super.connect()
    const phone = document.querySelector('meta[name="native-phone-session"][content="true"]')
    this.shareTarget.hidden = !phone
    this.noPhoneTarget.hidden = !!phone
  }

  async share(event) {
    if (!event.isTrusted || this.shareTarget.hidden || this.shareTarget.disabled) return
    if (!this.enabled) return this.#say("Update the iPhone app to share your location.")
    this.shareTarget.disabled = true
    let response
    try {
      response = await fetch(`${this.urlValue}.json`, {
        method: "POST",
        headers: { "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content },
        redirect: "error"
      })
    } catch {
      this.shareTarget.disabled = false
      return this.#say("Couldn't reach the conversation. Check your connection and try again.")
    }
    if (!this.element.isConnected) return
    if (response.status !== 204) {
      if (response.status === 409) return Turbo.visit(window.location.href, { action: "replace" })
      this.shareTarget.disabled = false
      return this.#say("Couldn't start this location request. Check that you're signed in on this iPhone.")
    }

    this.#say("Waiting for this iPhone…")
    this.send("share", { conversation: this.conversationValue, invocation: this.invocationValue }, ({ data }) => {
      if (data.received) return Turbo.visit(window.location.href, { action: "replace" })
      this.#say("Couldn't confirm whether the location was shared. Reopen this conversation to check.")
    })
  }

  #say(text) {
    this.statusTarget.textContent = text
    this.statusTarget.hidden = false
  }
}
