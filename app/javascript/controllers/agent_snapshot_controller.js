import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

// Serial polling for the conversation's whole snapshot. Every response
// replaces the whole projection, so a reconnect cannot duplicate or lose a
// message, and nothing depends on a sequence number surviving a restart.
// The connection generation fences out a reply that lands after a disconnect
// or a newer connection: a late, older view never overwrites a fresher one.
// Disconnecting only stops watching; it never cancels the run.
export default class extends Controller {
  static values = { url: String, interval: { type: Number, default: 1000 } }

  connect() {
    this.generation = (this.generation || 0) + 1
    this.poll(this.generation)
  }

  disconnect() {
    this.generation += 1
    clearTimeout(this.timer)
  }

  async poll(generation) {
    try {
      const response = await fetch(this.urlValue, {
        headers: { Accept: "text/vnd.turbo-stream.html" }, credentials: "same-origin", cache: "no-store"
      })
      const html = response.ok ? await response.text() : null
      if (generation !== this.generation) return
      if (html) {
        const incoming = html.match(/data-digest="([0-9a-f]+)"/)?.[1]
        const current = this.element.querySelector("[data-digest]")?.dataset.digest
        if (!incoming || incoming !== current) Turbo.renderStreamMessage(html)
      }
    } catch {
      // Network trouble: try again on the next tick with a fresh request.
    }
    if (generation === this.generation) this.timer = setTimeout(() => this.poll(generation), this.intervalValue)
  }
}
