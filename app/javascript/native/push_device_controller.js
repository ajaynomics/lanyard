import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

const CHECK = "Check that notifications are allowed for this app in the iPhone's Settings, then try again."

// The phone app's notifications (settings/notifications/_native_notifications):
// once iOS has said yes and given the device's token (Bridge Components'
// notification-token), it is posted here (Push::DevicesController) and the
// page refreshes to say they are on. Anything else says so on the page rather
// than nothing happening, and tells Rails why (Push::AttemptsController): an
// app without the component, no answer from the iPhone after a tap (iOS's
// permission refused, or registration failed: Pro's component never answers
// then), or a refused post. An empty token, the app's own component's answer
// when iOS refused or failed, the app reports itself, with iOS's code
// (PushRegistration): the bridge passes on only the token.
export default class extends Controller {
  static targets = [ "result" ]
  static values = { url: String, attemptsUrl: String, wait: { type: Number, default: 15000 } }

  disconnect() {
    clearTimeout(this.timer)
  }

  // On Turn on, ahead of the bridge's own action, which stops the tap there.
  turnOn() {
    this.resultTarget.hidden = true
    clearTimeout(this.timer)
    if (!this.application.getControllerForElementAndIdentifier(this.element, "bridge--notification-token")) {
      this.#report("no_component")
      return this.#say("This app can't turn notifications on: update it, then try again.")
    }
    this.timer = setTimeout(() => {
      this.#report("no_answer")
      this.#say(`The iPhone didn't answer. ${CHECK}`)
    }, this.waitValue)
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
