import { Controller } from "@hotwired/stimulus"

// Copies its text to the clipboard and says so for a moment. A reply's Copy
// button, and /copy, which presses the last one. On a touch screen that can
// share, it opens the system's share sheet instead, as a phone's apps do:
// the sheet has Copy too.
export default class extends Controller {
  static targets = ["label"]
  static values = { text: String }

  connect() {
    this.word = "Copy"
    if (!navigator.share || !matchMedia("(pointer: coarse)").matches) return
    this.word = "Share"
    this.element.dataset.shares = ""
    this.element.title = "Share this reply"
    if (this.hasLabelTarget) this.labelTarget.textContent = this.word
  }

  async copy() {
    if (this.element.dataset.shares !== undefined) return this.share()
    try {
      await navigator.clipboard.writeText(this.textValue)
      this.say("Copied")
    } catch {
      this.say("Couldn't copy")
    }
  }

  // Closing the sheet without choosing rejects with AbortError: nothing to say.
  async share() {
    try {
      await navigator.share({ text: this.textValue })
    } catch (error) {
      if (error.name !== "AbortError") this.say("Couldn't share")
    }
  }

  say(text) {
    if (!this.hasLabelTarget) return
    clearTimeout(this.timer)
    this.labelTarget.textContent = text
    // Shown even where the label is otherwise only for a screen reader.
    this.labelTarget.dataset.said = ""
    this.timer = setTimeout(() => {
      this.labelTarget.textContent = this.word
      delete this.labelTarget.dataset.said
    }, 1500)
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
