import { Controller } from "@hotwired/stimulus"

// A small setting (a switch, a menu) saves as soon as it changes. The server
// redirects back to the page, which morphs in place and says "Saved".
export default class extends Controller {
  save() {
    this.element.requestSubmit()
  }
}
