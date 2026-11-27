import { Controller } from "@hotwired/stimulus"

// Keep the list still while someone is choosing a row.
const HELD = { pointerenter: "pointer", pointerleave: "pointer", focusin: "focus", focusout: "focus", scrollend: "scroll" }

export default class extends Controller {
  static values = { sorted: Boolean }

  connect() {
    this.held = new Set()
    this.at = 0
    this.observer = new MutationObserver(() => this.changed())
    this.changed()
  }

  disconnect() { this.observer.disconnect(); clearTimeout(this.timer); clearTimeout(this.scrolling) }

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

  press(event) { this.pressed = event.target.closest(".tree-branch")?.dataset.agent }

  guard(event) {
    const agent = event.target.closest(".tree-branch")?.dataset.agent
    if (this.pressed && agent && agent !== this.pressed) { event.preventDefault(); event.stopImmediatePropagation() }
    this.pressed = null
  }

  changed() {
    this.quiet(() => {
      this.element.querySelectorAll(".conversation-row__link").forEach(link => {
        if (link.pathname === location.pathname) link.setAttribute("aria-current", "page")
        else link.removeAttribute("aria-current")
      })
      this.element.querySelectorAll(".tree-children").forEach(list => {
        const badge = list.closest(".tree-branch").querySelector(".tree-summary .tree-waiting")
        const waiting = [...list.querySelectorAll("[data-waiting]")].reduce((sum, row) => sum + Number(row.dataset.waiting), 0)
        badge.hidden = waiting === 0
        badge.textContent = `${waiting} waiting below`
      })
    })
    this.later(0)
  }

  later(wait) {
    clearTimeout(this.timer)
    if (!this.sortedValue) return
    this.timer = setTimeout(() => {
      if (this.held.size) return
      this.quiet(() => {
        this.element.querySelectorAll(".tree, .tree-children").forEach(list => {
          const sorted = [...list.children].sort((a, b) => this.news(b).localeCompare(this.news(a)))
          if (!sorted.some((row, index) => row !== list.children[index])) return
          list.append(...sorted)
          this.at = Date.now()
        })
      })
    }, Math.max(wait, this.at + 2000 - Date.now()))
  }

  quiet(change) {
    this.observer.disconnect()
    change()
    this.observer.observe(this.element, { childList: true, subtree: true, attributeFilter: [ "data-at", "data-waiting", "aria-current" ] })
  }

  news(branch) { return branch.querySelector(".conversation-row").dataset.at }
}
