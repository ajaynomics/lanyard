import { Controller } from "@hotwired/stimulus"

// Enter sends; Shift+Enter (or Enter while an input method is composing)
// makes a new line. While the bot works, Enter steers it (the Steer button
// shows then). The box grows with its text. (shadcn: Prompt Input.)
export default class extends Controller {
  static targets = ["input", "steer"]

  connect() {
    this.resize()
  }

  submitOnEnter(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return
    event.preventDefault()
    // Once: a message on its way is not sent again by a second Enter.
    if (!this.inputTarget.value.trim() || this.element.hasAttribute("aria-busy")) return
    this.element.requestSubmit(this.hasSteerTarget && this.steerTarget.checkVisibility() ? this.steerTarget : null)
  }

  resize() {
    this.inputTarget.style.height = "auto"
    this.inputTarget.style.height = `${Math.min(this.inputTarget.scrollHeight, 240)}px`
  }
}
