import { BridgeComponent } from "@hotwired/hotwire-native-bridge"

// How many cards wait on the person (layouts/_badge, re-broadcast as it
// changes), for the phone app's badge on the tab this names and on its icon
// (Phone/Bridge/TabBadgeComponent.swift). The web's badge reads the same.
export default class extends BridgeComponent {
  static component = "tab-badge"
  static values = { tab: String }

  connect() {
    super.connect()
    this.send("set", { count: Number(this.element.dataset.badgeCountValue) || 0, tab: this.tabValue })
  }
}
