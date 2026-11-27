import { Controller } from "@hotwired/stimulus"

// On a thread, typing with nothing else focused types into the composer, as
// in Slack. Bare slash and modifier shortcuts belong to shortcuts_controller;
// a slash typed in the box still opens the command menu. Esc leaves the box.
// A field, an open dialog or the canvas's editor keeps its own keys.
//
// The seam for a native app: a native shell would send the same character to
// type(key) rather than through a browser keydown.
export default class extends Controller {
  static targets = ["input"]

  press(event) {
    if (event.defaultPrevented || event.isComposing || event.metaKey || event.ctrlKey || event.altKey) return
    if (event.key === "Escape" && event.target === this.inputTarget) return this.leave()
    // Space still scrolls; the finder handles slash when the composer isn't focused.
    if (event.key.length !== 1 || event.key === " " || event.key === "/" || this.busyElsewhere(event.target)) return
    event.preventDefault()
    this.type(event.key)
  }

  type(key) {
    const input = this.inputTarget
    input.focus()
    const end = input.value.length
    input.setRangeText(key, end, end, "end")
    input.dispatchEvent(new Event("input", { bubbles: true }))
  }

  // An Esc that closed the command menu was marked handled there, so the box keeps the focus for that one.
  leave() {
    this.inputTarget.blur()
  }

  busyElsewhere(target) {
    if (document.querySelector("dialog[open]") || !this.inputTarget.checkVisibility()) return true
    return target instanceof Element && !!target.closest("input, textarea, select, button, [contenteditable], dialog, [role=dialog]")
  }
}
