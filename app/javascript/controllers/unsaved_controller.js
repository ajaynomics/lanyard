import { Controller } from "@hotwired/stimulus"

// Long text has an explicit Save. Leaving with changes unsaved asks first:
// the browser's own question on closing or reloading the tab, the app's
// dialog (layouts/_confirm) on going to another page.
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
    if (!this.dirty) return
    event.preventDefault()
    const url = event.detail.url
    Turbo.config.forms.confirm(this.messageValue, this.element, { textContent: "Leave" }).then(leave => {
      if (!leave) return
      this.dirty = false
      Turbo.visit(url)
    })
  }
}
