import { Controller } from "@hotwired/stimulus"

// Keep the search field in place while the frame redraws the results.
export default class extends Controller {
  submit() {
    this.element.requestSubmit()
  }

  searchAfterPause(event) {
    this.cancelSearch()
    if (!event.isComposing) this.searchTimer = setTimeout(() => this.submit(), 250)
  }

  cancelSearch() { clearTimeout(this.searchTimer) }
  disconnect() { this.cancelSearch() }
}
