import { Controller } from "@hotwired/stimulus"

// The agent list kept still under the hand (ConversationsHelper#sidebar_order_actions).
const HELD = { pointerenter: "pointer", pointerleave: "pointer", focusin: "focus", focusout: "focus", scrollend: "scroll" }

export default class extends Controller {
  static targets = [ "list" ]
  static values = { sorted: Boolean }

  connect() {
    this.held = new Set()
    this.at = 0
    this.observer = new MutationObserver(() => this.changed())
    this.changed()
  }

  disconnect() { this.observer.disconnect(); clearTimeout(this.timer) }

  hold(event) { if (event.type !== "focusin" || event.target.matches(":focus-visible")) this.held.add(HELD[event.type]) }

  release(event) {
    if (event.type === "focusout" && this.element.contains(event.relatedTarget)) return
    this.held.delete(HELD[event.type])
    this.later(1000)
  }

  scrolled() {
    this.held.add("scroll")
    clearTimeout(this.scrolling)
    this.scrolling = setTimeout(() => this.release({ type: "scrollend" }), 300)
  }

  press(event) { this.pressed = event.target.closest(".conversation-row")?.id }

  guard(event) {
    const row = event.target.closest(".conversation-row")?.id
    if (this.pressed && row && row !== this.pressed) { event.preventDefault(); event.stopImmediatePropagation() }
    this.pressed = null
  }

  changed() {
    this.quiet(() => {
      const seen = new Set()
      this.rows().forEach(row => {
        if (seen.has(row.id)) return row.remove()
        seen.add(row.id)
        const link = row.querySelector("a")
        link.pathname === location.pathname ? link.setAttribute("aria-current", "page") : link.removeAttribute("aria-current")
      })
    })
    this.later(0)
  }

  later(wait) {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      const rows = this.sorted()
      if (this.held.size || !this.sortedValue || !rows.some((row, index) => row !== this.listTarget.children[index])) return
      this.quiet(() => this.listTarget.append(...rows))
      this.at = Date.now()
    }, Math.max(wait, this.at + 2000 - Date.now()))
  }

  quiet(change) {
    this.observer.disconnect()
    change()
    this.observer.observe(this.element, { childList: true, subtree: true, attributeFilter: [ "data-at", "aria-current" ] })
  }

  rows() { return [ ...this.element.querySelectorAll(".conversation-row") ] }

  sorted() { return this.rows().sort((a, b) => b.dataset.at.localeCompare(a.dataset.at)) }
}
