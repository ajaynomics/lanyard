import { Controller } from "@hotwired/stimulus"

// The agent's screen through noVNC (vendored, pinned in the importmap). The
// websocket goes to this page's own address; Rails relays it to the agent's
// Sprite, waking it first, which can take a minute. You can watch and type
// while the agent works. noVNC loads only on this page.
export default class extends Controller {
  static targets = ["display", "status"]

  async connect() {
    const { default: RFB } = await import("@novnc/novnc")
    if (!this.element.isConnected) return
    const url = new URL(window.location.href)
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:"
    url.search = ""
    this.say("Waking the computer…")
    this.rfb = new RFB(this.displayTarget, url.href, { shared: true, wsProtocols: ["binary"] })
    this.rfb.scaleViewport = true
    this.rfb.addEventListener("connect", () => this.say(""))
    this.rfb.addEventListener("disconnect", event => this.say(event.detail.clean ? "The screen closed." : "Couldn't open the screen. Reload to try again."))
  }

  disconnect() {
    this.rfb?.disconnect()
    this.rfb = null
  }

  say(text) {
    this.statusTarget.textContent = text
    this.statusTarget.hidden = text === ""
  }
}
