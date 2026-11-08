import { Controller } from "@hotwired/stimulus"

// The Mac's keys, with ⌘ (Ctrl elsewhere): ⌘N a new agent, ⌘F the agent
// search, ⌘1 to ⌘9 the agents in the list, ⌘/ the help. A browser keeps some
// of these for itself (⌘N and ⌘1–9 in a tab); in the installed app they are
// the app's. The help lists them (CommandsHelper#app_shortcuts).
export default class extends Controller {
  static targets = ["search"]
  static values = { newAgent: String }

  press(event) {
    if (!(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey || event.defaultPrevented) return
    const action = this.actionFor(event.key)
    if (action && action() !== false) event.preventDefault()
  }

  actionFor(key) {
    if (key === "n") return () => Turbo.visit(this.newAgentValue)
    if (key === "f") return () => this.focusSearch()
    if (key === "/") return () => this.openHelp()
    if (/^[1-9]$/.test(key)) return () => this.openAgent(Number(key))
  }

  // False where there is no search on screen, so the browser's own find runs.
  focusSearch() {
    const search = this.searchTargets.find(box => box.checkVisibility())
    if (!search) return false
    search.focus()
    search.select()
  }

  openHelp() {
    const help = document.getElementById("help_dialog")
    if (!help) return false
    help.showModal()
  }

  openAgent(number) {
    const link = document.querySelectorAll(".chat-sidebar .conversation-row__link, #conversations .conversation-row__link")[number - 1]
    if (!link) return false
    link.click()
  }
}
