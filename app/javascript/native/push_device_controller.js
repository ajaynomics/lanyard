import { BridgeComponent } from "@hotwired/hotwire-native-bridge"
import { Turbo } from "@hotwired/turbo-rails"

const CHECK = "Check that notifications are allowed for this app in the iPhone's Settings, then try again."

// Read iOS's permission separately from the token request. The Pro token
// bridge doesn't answer when permission is denied. Older apps still use
// their original token flow.
export default class extends BridgeComponent {
  static component = "notification-status"
  static get shouldLoad() { return true }
  static get readsPermission() { return super.shouldLoad }
  static targets = [ "result", "available", "denied" ]
  static values = { url: String, attemptsUrl: String, wait: { type: Number, default: 15000 } }

  connect() {
    super.connect()
    if (this.hasDeniedTarget && this.constructor.readsPermission) this.#readPermission()
  }

  disconnect() {
    super.disconnect()
    clearTimeout(this.timer)
    clearTimeout(this.permissionTimer)
  }

  turnOn(event) {
    this.resultTarget.hidden = true
    clearTimeout(this.timer)
    const token = this.application.getControllerForElementAndIdentifier(this.element, "bridge--notification-token")
    if (!token) {
      this.#report("no_component")
      return this.#say("This app can't turn notifications on: update it, then try again.")
    }
    if (this.constructor.readsPermission) {
      return this.#readPermission(denied => { if (!denied) this.#requestToken(token, event) })
    }
    this.#requestToken(token, event)
  }

  #readPermission(proceed) {
    clearTimeout(this.permissionTimer)
    this.removePendingCallbacks()
    this.removePendingMessages()
    this.permissionTimer = setTimeout(() => {
      this.removePendingCallbacks()
      this.removePendingMessages()
      if (proceed) this.#say("Couldn't check notification permission on this iPhone. Try again.")
    }, 2000)
    this.send("read", {}, ({ data }) => {
      clearTimeout(this.permissionTimer)
      const denied = data.status === "denied"
      this.availableTarget.hidden = denied
      this.deniedTarget.hidden = !denied
      if (denied) clearTimeout(this.timer)
      proceed?.(denied)
    })
  }

  #requestToken(token, event) {
    this.timer = setTimeout(() => {
      this.#report("no_answer")
      this.#say(`The iPhone didn't answer. ${CHECK}`)
    }, this.waitValue)
    token.get(event)
  }

  async register({ detail: { token } }) {
    clearTimeout(this.timer)
    if (!token) return this.#say(`The iPhone didn't turn notifications on. ${CHECK}`)
    let response
    try {
      response = await this.#post(this.urlValue, { token })
    } catch {
      this.#report("rejected")
      return this.#say("Couldn't turn on notifications here: no answer from this app. Try again.")
    }
    if (response.ok) return Turbo.visit(window.location.href, { action: "replace" })
    this.#report("rejected", response.status)
    this.#say(`Couldn't turn on notifications here (HTTP ${response.status}).`)
  }

  #say(text) {
    this.resultTarget.textContent = text
    this.resultTarget.hidden = false
  }

  // Rails keeps why (Push::Attempt); the page has already said so, whatever becomes of this.
  #report(outcome, code) {
    this.#post(this.attemptsUrlValue, { outcome, code }).catch(() => {})
  }

  #post(url, body) {
    return fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content },
      body: JSON.stringify(body)
    })
  }
}
