import { Controller } from "@hotwired/stimulus"

// The button that opens the agents list as a side panel on a narrow screen
// (shadcn: Sheet): the same sidebar inside a native <dialog>, opened modal, so
// Esc closes it and focus stays inside for free; a tap on the backdrop closes
// it too. The dialog is the one aria-controls names. Wider screens show the
// dialog as the fixed sidebar (layout.css) and hide this button.
export default class extends Controller {
  // Focus starts on the open agent, not the search box, which would raise a
  // phone's keyboard over the list.
  open() {
    this.dialog.showModal()
    this.dialog.querySelector("[aria-current=page]")?.focus()
  }

  // A click on the backdrop lands on the dialog itself; one inside lands on the sidebar.
  closeOnBackdrop(event) {
    if (event.target === this.dialog) this.dialog.close()
  }

  // Turbo's snapshot of the page keeps no open panel.
  close() {
    if (this.dialog?.open) this.dialog.close()
  }

  get dialog() {
    return document.getElementById(this.element.getAttribute("aria-controls"))
  }
}
