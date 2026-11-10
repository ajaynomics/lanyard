import { Controller } from "@hotwired/stimulus"

// Notifications on this device (settings/accounts/_notifications). The
// browser holds the truth: whether it allows them, and whether it has an
// address with its push service. The row says which (data-state): on, off,
// blocked, unsupported, or install (an iPhone or iPad outside the Home
// Screen, where iOS has no Web Push). It is on only when the browser has an
// address and Rails has it too, so a device removed in the list reads off.
export default class extends Controller {
  static targets = ["switch", "result"]
  static values = { key: String, url: String }

  connect() {
    this.refresh()
  }

  async refresh() {
    this.show(await this.state())
  }

  // The permission is asked from this click and nowhere else: never on load.
  async toggle() {
    const on = this.switchTarget.checked
    this.switchTarget.disabled = true
    try {
      on ? await this.subscribe() : await this.unsubscribe()
    } catch (error) {
      console.warn("Notifications could not be changed", error)
    }
    // The list of devices follows (morphed in place; this row is kept).
    window.Turbo?.visit(window.location.href, { action: "replace" })
    await this.refresh()
  }

  // One notice to this device, through the server's real sender; says what its push service answered.
  async test(event) {
    const button = event.currentTarget
    const subscription = await this.subscription()
    const row = subscription && this.row(subscription)
    if (!row) return this.refresh()
    button.disabled = true
    this.resultTarget.textContent = "Sending…"
    try {
      const response = await this.request("POST", row.dataset.pushTestUrl)
      this.resultTarget.textContent = response.ok ? (await response.json()).message : `Sending failed (HTTP ${response.status}).`
    } catch {
      this.resultTarget.textContent = "Sending failed: no answer from this app."
    }
    button.disabled = false
  }

  async subscribe() {
    if (await Notification.requestPermission() !== "granted") return
    const registration = await navigator.serviceWorker.ready
    // A fresh address each time: one made with keys the install has since replaced would never be delivered to.
    await (await registration.pushManager.getSubscription())?.unsubscribe()
    const subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: decode(this.keyValue) })
    const { endpoint, keys: { p256dh, auth } } = subscription.toJSON()
    const response = await this.request("POST", this.urlValue, { push_subscription: { endpoint, p256dh_key: p256dh, auth_key: auth } })
    if (!response.ok) await subscription.unsubscribe()
  }

  async unsubscribe() {
    const subscription = await this.subscription()
    if (!subscription) return
    const row = this.row(subscription)
    if (row) await this.request("DELETE", row.dataset.pushUrl)
    await subscription.unsubscribe()
  }

  async state() {
    if (appleMobile() && !installed()) return "install"
    if (!("serviceWorker" in navigator && "PushManager" in window && "Notification" in window)) return "unsupported"
    if (Notification.permission === "denied") return "blocked"
    const subscription = await this.subscription()
    document.querySelectorAll("[data-this-device]").forEach(mark => mark.hidden = true)
    const row = subscription && this.row(subscription)
    if (row) row.querySelector("[data-this-device]").hidden = false
    return Notification.permission === "granted" && row ? "on" : "off"
  }

  show(state) {
    this.element.dataset.state = state
    this.switchTarget.checked = state === "on"
    this.switchTarget.disabled = state !== "on" && state !== "off"
  }

  async subscription() {
    const registration = await navigator.serviceWorker.getRegistration("/")
    return registration?.pushManager.getSubscription()
  }

  row(subscription) {
    return document.querySelector(`[data-push-endpoint="${CSS.escape(subscription.endpoint)}"]`)
  }

  request(method, url, body) {
    return fetch(url, {
      method,
      headers: { "Content-Type": "application/json", Accept: "application/json",
                 "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content },
      body: body && JSON.stringify(body)
    })
  }
}

// iPadOS calls itself a Mac; its touch screen gives it away.
const appleMobile = () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (/Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1)
const installed = () => matchMedia("(display-mode: standalone)").matches || navigator.standalone === true

// The VAPID public key, base64url, as the bytes pushManager.subscribe wants.
const decode = key => {
  const base64 = key.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(key.length / 4) * 4, "=")
  return Uint8Array.from(atob(base64), character => character.charCodeAt(0))
}
