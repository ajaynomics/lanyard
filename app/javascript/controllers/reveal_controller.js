import { Controller } from "@hotwired/stimulus"

// On a touch screen, a tap on a bubble shows its message's actions (Edit,
// Copy, Branch) and hides any other's; a second tap hides them. With a mouse
// they show on hover, so this changes nothing there (layout.css).
export default class extends Controller {
  toggle(event) {
    if (!event.target.closest(".ui-bubble") || event.target.closest("a, button, summary")) return
    if (!document.getSelection()?.isCollapsed) return
    const message = event.target.closest(".ui-message")
    const shown = message.hasAttribute("data-revealed")
    this.element.querySelectorAll("[data-revealed]").forEach(other => other.removeAttribute("data-revealed"))
    message.toggleAttribute("data-revealed", !shown)
  }
}
