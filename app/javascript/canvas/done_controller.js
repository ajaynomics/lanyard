import { Controller } from "@hotwired/stimulus"

// Done closes the canvas beside the thread. One job, so a Hotwire Native
// bridge component ("canvas-done": the native Done button of a modal) can
// replace it without the rest noticing. On the canvas's own page there is no
// thread to return to in place, so the link goes back to it.
//
// Unsaved words ask first: the close is announced, cancelable, and whoever
// stops it (unsaved#guard) calls proceed when the person says leave.
export default class extends Controller {
  close(event) {
    const frame = this.element.closest(".canvas-frame")
    if (!frame) return
    event.preventDefault()
    const proceed = () => {
      frame.removeAttribute("src")
      frame.replaceChildren()
    }
    if (!this.dispatch("close", { cancelable: true, detail: { proceed } }).defaultPrevented) proceed()
  }
}
