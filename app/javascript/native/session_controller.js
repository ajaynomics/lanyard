import { BridgeComponent } from "@hotwired/hotwire-native-bridge"

// Signing out from the Settings tab, which is the web's /settings
// (settings/_native_rows). Rails has ended the session, revoked the Watch's
// tokens and forgotten this iPhone's notifications; what is left is the
// app's: its cookies, the Watch, and tabs that start afresh, signed out
// (Phone/Bridge/SessionComponent.swift). Told only once Rails has answered,
// so a sign-out that never reached it leaves the person signed in, as they are.
export default class extends BridgeComponent {
  static component = "session"

  signedOut({ detail: { success } }) {
    if (success) this.send("signed-out")
  }
}
