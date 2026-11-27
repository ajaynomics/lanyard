import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["frame", "revision"]
  static values = { url: String }

  remember({ currentTarget: group }) {
    if (group.dataset.wasOpen === String(group.open)) return
    this.showState(group)
    const value = document.cookie.split("; ").find(part => part.startsWith("collapsed_agents="))?.slice(17) || ""
    const ids = new Set(value.length <= 1919 ? value.split("|").slice(0, 96).filter(id => /^[1-9]\d{0,18}$/.test(id)) : [])
    ids.delete(group.dataset.group)
    if (!group.open) ids.add(group.dataset.group)
    document.cookie = `collapsed_agents=${[...ids].slice(-96).join("|")}; Path=/; Max-Age=31536000; SameSite=Lax${location.protocol === "https:" ? "; Secure" : ""}`
  }

  dismissMenu(event) {
    event.currentTarget.closest("[popover]")?.hidePopover()
  }

  revisionTargetConnected(revision) {
    if (revision.dataset.moved) this.moved = revision.dataset.moved
    if (this.frameTarget.src) this.frameTarget.reload()
    else this.frameTarget.src = this.urlValue
  }

  beforeRender() {
    const active = document.activeElement
    if (!this.frameTarget.contains(active)) return
    this.focus = { id: active.id || active.closest(".conversation-row")?.id, link: active.matches("a") }
  }

  rendered() {
    const path = this.frameTarget.closest("[data-sidebar-order-current-value]")?.dataset.sidebarOrderCurrentValue || location.pathname
    this.reveal([...this.frameTarget.querySelectorAll(".conversation-row__link")].find(link => link.pathname === path))
    if (this.moved) {
      const button = document.getElementById(`reporting_actions_agent_${this.moved}`)
      this.reveal(button)
      button?.focus()
    } else if (this.focus?.id) {
      const row = document.getElementById(this.focus.id)
      const focus = this.focus.link ? row?.querySelector(".conversation-row__link") : row
      if (focus?.getClientRects().length) focus.focus({ preventScroll: true })
    }
    this.moved = this.focus = null
  }

  reveal(element) {
    for (let group = element?.closest("details[data-group]"); group; group = group.parentElement.closest("details[data-group]")) {
      group.open = true
      this.showState(group)
    }
  }

  showState(group) {
    group.dataset.wasOpen = String(group.open)
    group.firstElementChild.setAttribute("aria-label", `${group.open ? "Hide" : "Show"} reports for ${group.dataset.name}`)
  }
}
