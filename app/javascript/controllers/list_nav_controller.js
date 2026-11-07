import { Controller } from "@hotwired/stimulus"

// Up and down arrows, Home and End move focus along a list's rows, including
// rows a later page added; Enter follows the focused link as any link does.
export default class extends Controller {
  static targets = ["link"]

  move(event) {
    const links = this.linkTargets
    const index = links.indexOf(document.activeElement)
    if (index === -1) return
    const next = { ArrowDown: index + 1, ArrowUp: index - 1, Home: 0, End: links.length - 1 }[event.key]
    if (next === undefined) return
    event.preventDefault()
    links[Math.max(0, Math.min(next, links.length - 1))].focus()
  }
}
