import { Controller } from "@hotwired/stimulus"

// Rows in their place as they change live (Conversation::Standing says how).
export default class extends Controller {
  static targets = [ "list" ]
  static values = { sorted: Boolean }

  connect() {
    this.observer = new MutationObserver(() => this.arrange())
    this.arrange()
  }

  disconnect() { this.observer.disconnect() }

  arrange() {
    this.observer.disconnect()
    const seen = new Set()
    const rows = [ ...this.element.querySelectorAll(".conversation-row") ].filter(row => {
      if (seen.has(row.id)) return row.remove()
      return seen.add(row.id)
    })
    if (this.sortedValue && this.hasListTarget) {
      const sorted = [ ...rows ].sort((a, b) => a.dataset.rank - b.dataset.rank || b.dataset.at.localeCompare(a.dataset.at))
      if (sorted.some((row, index) => row !== this.listTarget.children[index])) this.listTarget.append(...sorted)
    }
    rows.forEach(row => {
      const link = row.querySelector("a")
      if (link.pathname === location.pathname) link.setAttribute("aria-current", "page")
      else link.removeAttribute("aria-current")
    })
    this.observer.observe(this.element, { childList: true, subtree: true, attributeFilter: [ "data-rank", "data-at", "aria-current" ] })
  }
}
