import { Controller } from "@hotwired/stimulus"

// Long text has an explicit Save. Leaving with changes unsaved asks first:
// the browser's own question on closing or reloading the tab, the app's
// dialog (layouts/_confirm) on going to another page or closing the canvas.
export default class extends Controller {
  static values = { message: { type: String, default: "Leave without saving? Your changes will be lost." } }

  change() {
    this.dirty = true
  }

  save() {
    this.dirty = false
  }

  warn(event) {
    if (!this.dirty) return
    event.preventDefault()
    event.returnValue = ""
  }

  confirm(event) {
    const url = event.detail.url
    this.guard(event, () => Turbo.visit(url))
  }

  // A cancelable leaving that says how to go on (canvas-done:close).
  guard(event, proceed = event.detail.proceed) {
    if (!this.dirty) return
    event.preventDefault()
    Turbo.config.forms.confirm(this.messageValue, this.element, { textContent: "Leave" }).then(leave => {
      if (!leave) return
      this.dirty = false
      proceed()
    })
  }
}
