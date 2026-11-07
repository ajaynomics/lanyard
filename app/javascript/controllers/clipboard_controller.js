import { Controller } from "@hotwired/stimulus"

// Copies its text to the clipboard and says so for a moment. A reply's Copy
// button, and /copy, which presses the last one.
export default class extends Controller {
  static targets = ["label"]
  static values = { text: String }

  async copy() {
    try {
      await navigator.clipboard.writeText(this.textValue)
      this.say("Copied")
    } catch {
      this.say("Couldn't copy")
    }
  }

  say(text) {
    if (!this.hasLabelTarget) return
    clearTimeout(this.timer)
    this.labelTarget.textContent = text
    this.timer = setTimeout(() => { this.labelTarget.textContent = "Copy" }, 1500)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
