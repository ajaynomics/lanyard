import { Controller } from "@hotwired/stimulus"

// A one-line form on a page that morphs while it is typed in (a helper's Message, in the Helpers panel): the
// morph leaves the focused box's words alone, and the form empties once they are sent (docs/design.md,
// "Typing survives"). Other one-line boxes empty with the page, as they should after Enter.
export default class extends Controller {
  keep(event) {
    if (event.detail.attributeName === "value" && event.target === document.activeElement) event.preventDefault()
  }

  sent({ detail }) {
    if (detail.success) this.element.reset()
  }
}
