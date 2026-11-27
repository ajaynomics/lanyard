import { Controller } from "@hotwired/stimulus"

// Arrow keys navigate visible rows; Enter follows the focused link.
export default class extends Controller {
  static targets = ["link"]

  move(event) {
    const links = this.linkTargets.filter(link => !link.closest("[hidden]") && link.getClientRects().length)
    const index = links.indexOf(document.activeElement)
    if (index === -1) return
    const next = { ArrowDown: index + 1, ArrowUp: index - 1, Home: 0, End: links.length - 1 }[event.key]
    if (next === undefined) return
    event.preventDefault()
    links[Math.max(0, Math.min(next, links.length - 1))].focus()
  }
}
