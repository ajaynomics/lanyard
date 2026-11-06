import { Controller } from "@hotwired/stimulus"

// Enter sends; Shift+Enter (or Enter while an input method is composing)
// makes a new line. The box grows with its text. (shadcn: Prompt Input.)
export default class extends Controller {
  static targets = ["input"]

  connect() {
    this.resize()
  }

  submitOnEnter(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return
    event.preventDefault()
    // Once: a message on its way is not sent again by a second Enter.
    if (this.inputTarget.value.trim() && !this.element.hasAttribute("aria-busy")) this.element.requestSubmit()
  }

  resize() {
    this.inputTarget.style.height = "auto"
    this.inputTarget.style.height = `${Math.min(this.inputTarget.scrollHeight, 240)}px`
  }
}
