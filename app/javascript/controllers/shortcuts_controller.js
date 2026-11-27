import { Controller } from "@hotwired/stimulus"

// Browser shortcuts stay with the browser, except the app's explicit finder chord.
const shortcuts = new Map([["n", "newAgent"], ["k", "focusSearch"], ["/", "openHelp"], [",", "openSettings"]])

export default class extends Controller {
  static targets = ["search"]
  static values = { newAgent: String, settings: String }

  press(event) {
    if (event.defaultPrevented || event.isComposing || event.altKey || event.shiftKey) return
    const action = event.metaKey || event.ctrlKey ? shortcuts.get(event.key) : this.plainAction(event)
    if (action && this[action]() !== false) event.preventDefault()
  }

  plainAction(event) {
    if (event.key === "/" && !document.querySelector("dialog[open]") &&
        !event.target.closest?.("input, textarea, select, [contenteditable]:not([contenteditable=false])")) return "focusSearch"
  }

  focusSearch() {
    const search = this.searchTargets.find(box => box.checkVisibility())
    if (search) { search.focus(); search.select() }
    else Turbo.visit("/conversations?focus=search")
  }

  newAgent() { Turbo.visit(this.newAgentValue) }
  openSettings() { Turbo.visit(this.settingsValue) }

  openHelp() {
    const help = document.getElementById("help_dialog")
    if (!help) return false
    help.showModal()
  }
}
