import { BridgeComponent } from "@hotwired/hotwire-native-bridge"

// A waiting card opened alone in the phone app (approvals/show): Allow and
// Deny in the app's own bar at the foot, with a haptic as each is tapped
// (Phone/Bridge/ApprovalComponent.swift). A tap presses the page's own
// button, so the answer goes exactly as the web's does. No Bridge Components
// equivalent exists, so this one is the app's. The app greys its buttons as
// it answers; an answer that never arrived tells it to offer them again, and
// says why where nothing else will (a refusal brings its own flash).
export default class extends BridgeComponent {
  static component = "approval"
  static targets = [ "allow", "deny", "failure" ]

  connect() {
    super.connect()
    const allow = this.hasAllowTarget ? this.allowTarget.textContent.trim() : null
    const deny = this.hasDenyTarget ? this.denyTarget.textContent.trim() : null
    this.send("connect", { allow, deny }, message => {
      const button = message.data.choice === "allow" ? this.allowTarget : this.denyTarget
      button?.click()
    })
  }

  failed({ detail: { success, fetchResponse } }) {
    if (success) return
    this.send("failed")
    if (fetchResponse && fetchResponse.statusCode < 500) return
    this.failureTarget.textContent = fetchResponse ? `Not sent (HTTP ${fetchResponse.statusCode}). Try again.` : "Not sent: no connection. Try again."
    this.failureTarget.hidden = false
  }

  disconnect() {
    super.disconnect()
    this.send("disconnect")
  }
}
