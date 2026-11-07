import { Controller } from "@hotwired/stimulus"

// The list's search, sort and filter form: a select sends it as soon as it
// changes, and "/" puts the cursor in the search box.
export default class extends Controller {
  static targets = ["search"]

  submit() {
    this.element.requestSubmit()
  }

  focusSearch(event) {
    if (event.key !== "/") return
    // Typing a "/" into a box is typing, not a shortcut.
    if (event.target.closest?.("input, textarea, select, [contenteditable]")) return
    event.preventDefault()
    this.searchTarget.focus()
  }
}
