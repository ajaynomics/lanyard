import { Controller } from "@hotwired/stimulus"

// Submits its form as soon as the page shows it: the phone app's sign-in sheet
// goes straight on to the provider. The button stays, for a browser without scripts.
export default class extends Controller {
  connect() {
    this.element.requestSubmit()
  }
}
