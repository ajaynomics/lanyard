import { Controller } from "@hotwired/stimulus"

// Signing out forgets every unsent draft (composer_controller keeps them in
// localStorage under draft:<conversation id>), so the next person on this
// browser does not find them.
export default class extends Controller {
  clear() {
    for (const key of Object.keys(localStorage)) if (key.startsWith("draft:")) localStorage.removeItem(key)
  }
}
